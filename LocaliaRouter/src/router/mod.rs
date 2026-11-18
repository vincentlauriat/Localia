//! Where a request goes (Decisions 5–8): the active model's engine when it is up, else the first equivalent
//! that is up, holds the model and has a large enough context window. Nothing is sticky: every decision tries
//! the primary first. R1 never starts an engine or loads a model, and the measured speed never changes a
//! decision.

mod probe;
mod speed;

pub use probe::{HttpProbe, PROBE_TIMEOUT, PROBE_TTL};
pub use speed::{Speed, SpeedTracker, MIN_OUTPUT, SLOW_TPS, TO_OK, TO_SLOW, WINDOW};

use crate::config::{RoutingConfig, TargetSpec};
use crate::engine::EngineKind;
use async_trait::async_trait;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::sync::Notify;

/// How long a `Loading` primary is waited for before it is skipped.
pub const LOAD_GRACE: Duration = Duration::from_secs(90);
/// How often a `Loading` primary is polled while a request waits.
pub const LOAD_POLL: Duration = Duration::from_millis(500);
/// How often the monitor probes the active engine.
pub const MONITOR_PERIOD: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum EngineHealth {
    Up,
    /// llama.cpp or MLX answering 503 on `/health` while it loads a model.
    Loading,
    Down,
}

/// What the router knows of the engines. Implementations answer quickly (short timeouts) and may cache.
#[async_trait]
pub trait Probe: Send + Sync {
    async fn health(&self, k: EngineKind) -> EngineHealth;
    /// Whether `k` serves `model` now (Ollama: installed; llama.cpp: the loaded alias). Not asked for MLX.
    async fn listed(&self, k: EngineKind, model: &str) -> bool;
    /// Drops what is cached about `k` (after a refused connection), so the next probe asks again.
    fn forget(&self, _k: EngineKind) {}
}

/// Time, injectable so waits are deterministic in tests.
#[async_trait]
pub trait Clock: Send + Sync {
    fn now(&self) -> Instant;
    async fn sleep(&self, d: Duration);
}

/// The real clock (`Instant::now`, `tokio::time::sleep`).
pub struct SystemClock;

#[async_trait]
impl Clock for SystemClock {
    fn now(&self) -> Instant {
        Instant::now()
    }

    async fn sleep(&self, d: Duration) {
        tokio::time::sleep(d).await
    }
}

/// Why a target was chosen; recorded in the `reason` column.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Reason {
    Primary,
    EngineDown,
    /// A legacy `/s/<session>/<engine>/` request (Decision 3); decided by the relay, never by `decide`.
    Pinned,
}

impl Reason {
    pub fn as_str(self) -> &'static str {
        match self {
            Reason::Primary => "primary",
            Reason::EngineDown => "engine-down",
            Reason::Pinned => "pinned",
        }
    }
}

#[derive(Clone, PartialEq, Debug)]
pub struct Decision {
    pub target: TargetSpec,
    pub reason: Reason,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RouteError {
    /// The app has not pushed an active model.
    NoActiveModel,
    /// Neither the active engine nor any eligible equivalent is up; `engine` is the active one.
    Unavailable { engine: EngineKind },
}

/// The `route` object of `/localia/health`.
#[derive(Serialize, Clone, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct RouteStatus {
    /// `idle` (no active model) | `local` | `fallback` | `down`.
    pub state: &'static str,
    pub engine: Option<EngineKind>,
    pub model: Option<String>,
    /// `primary` | `engine-down`, from the last decision.
    pub reason: Option<&'static str>,
    /// `unknown` | `ok` | `slow`.
    pub speed: &'static str,
    /// An engine whose stream died after a 2xx; cleared by its next successful response.
    pub engine_failure: Option<EngineKind>,
}

struct State {
    cfg: Option<RoutingConfig>,
    /// Bumped whenever the active target changes, so a decision started before the change is not recorded.
    generation: u64,
    last: Option<Result<Decision, RouteError>>,
    /// The last probe answer per engine, as seen by decisions, the monitor and `mark_down`.
    seen: HashMap<EngineKind, EngineHealth>,
    speed: SpeedTracker,
    engine_failure: Option<EngineKind>,
}

impl State {
    fn active(&self) -> Option<&TargetSpec> {
        self.cfg.as_ref().and_then(|c| c.active.as_ref())
    }
}

pub struct Router {
    probe: Arc<dyn Probe>,
    clock: Arc<dyn Clock>,
    state: Mutex<State>,
    /// Wakes the monitor when the config changes.
    wake: Notify,
}

fn same_target(a: &TargetSpec, b: &TargetSpec) -> bool {
    a.engine == b.engine && a.model == b.model
}

impl Router {
    pub fn new(probe: Arc<dyn Probe>, clock: Arc<dyn Clock>, cfg: Option<RoutingConfig>) -> Router {
        Router {
            probe,
            clock,
            state: Mutex::new(State {
                cfg,
                generation: 0,
                last: None,
                seen: HashMap::new(),
                speed: SpeedTracker::default(),
                engine_failure: None,
            }),
            wake: Notify::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Applies a pushed routing config. A new active target forgets the last decision and the speed samples;
    /// the same config pushed again keeps them.
    pub fn set_config(&self, cfg: Option<RoutingConfig>) {
        {
            let mut st = self.lock();
            let changed = match (st.active(), cfg.as_ref().and_then(|c| c.active.as_ref())) {
                (Some(a), Some(b)) => !same_target(a, b),
                (None, None) => false,
                _ => true,
            };
            if changed {
                st.generation += 1;
                st.last = None;
                st.seen.clear();
                st.speed.reset();
            }
            st.cfg = cfg;
        }
        // Stored as a permit when the monitor is busy probing, so the push is never missed.
        self.wake.notify_one();
    }

    /// Chooses the target for one request. `declared_context` is the window the session was launched with;
    /// without one the active model's window applies. Waits up to `LOAD_GRACE` for a loading primary.
    pub async fn decide(&self, declared_context: Option<u32>) -> Result<Decision, RouteError> {
        let (cfg, active, generation) = {
            let st = self.lock();
            (st.cfg.clone(), st.active().cloned(), st.generation)
        };
        let (Some(cfg), Some(active)) = (cfg, active) else {
            let mut st = self.lock();
            if st.generation == generation {
                st.last = Some(Err(RouteError::NoActiveModel));
            }
            return Err(RouteError::NoActiveModel);
        };
        let result = self.choose(&cfg, &active, declared_context).await;
        let mut st = self.lock();
        if st.generation == generation {
            st.last = Some(result.clone());
        }
        result
    }

    async fn choose(
        &self,
        cfg: &RoutingConfig,
        active: &TargetSpec,
        declared_context: Option<u32>,
    ) -> Result<Decision, RouteError> {
        let mut health = self.probe_health(active.engine).await;
        if health == EngineHealth::Loading {
            let deadline = self.clock.now() + LOAD_GRACE;
            while health == EngineHealth::Loading && self.clock.now() < deadline {
                self.clock.sleep(LOAD_POLL).await;
                health = self.probe_health(active.engine).await;
            }
        }
        if health == EngineHealth::Up && self.eligible(cfg, active).await {
            return Ok(Decision {
                target: active.clone(),
                reason: Reason::Primary,
            });
        }
        let needed = declared_context.unwrap_or(active.context_tokens);
        for eq in &cfg.equivalents {
            if same_target(eq, active) || eq.context_tokens < needed {
                continue;
            }
            if self.probe_health(eq.engine).await == EngineHealth::Up
                && self.eligible(cfg, eq).await
            {
                return Ok(Decision {
                    target: eq.clone(),
                    reason: Reason::EngineDown,
                });
            }
        }
        Err(RouteError::Unavailable {
            engine: active.engine,
        })
    }

    /// Single-model engines must serve the model now; MLX is known only through the app's `mlxModel`.
    async fn eligible(&self, cfg: &RoutingConfig, t: &TargetSpec) -> bool {
        match t.engine {
            EngineKind::Mlx => cfg.mlx_model.as_deref() == Some(t.model.as_str()),
            k => self.probe.listed(k, &t.model).await,
        }
    }

    async fn probe_health(&self, k: EngineKind) -> EngineHealth {
        let h = self.probe.health(k).await;
        self.lock().seen.insert(k, h);
        h
    }

    /// A connection to `k` was refused: show it down now and make the next probe ask again.
    pub fn mark_down(&self, k: EngineKind) {
        self.probe.forget(k);
        self.lock().seen.insert(k, EngineHealth::Down);
    }

    /// A finished response from `target`; only the active target's speed is tracked.
    pub fn record_decode_speed(&self, target: &TargetSpec, output_tokens: u64, decode_ms: u64) {
        let mut st = self.lock();
        if st.active().is_some_and(|a| same_target(a, target)) {
            st.speed.record(output_tokens, decode_ms);
        }
    }

    /// A stream from `k` died after its 2xx (the engine looks up but its generation failed).
    pub fn report_stream_failure(&self, k: EngineKind) {
        self.lock().engine_failure = Some(k);
    }

    /// A response from `k` completed: clears a failure reported for `k`.
    pub fn report_stream_success(&self, k: EngineKind) {
        let mut st = self.lock();
        if st.engine_failure == Some(k) {
            st.engine_failure = None;
        }
    }

    /// Cached state only; never probes.
    pub fn status(&self) -> RouteStatus {
        let st = self.lock();
        let base = RouteStatus {
            state: "idle",
            engine: None,
            model: None,
            reason: None,
            speed: st.speed.state().as_str(),
            engine_failure: st.engine_failure,
        };
        let Some(active) = st.active() else {
            return base;
        };
        let is_down = |k: EngineKind| st.seen.get(&k) == Some(&EngineHealth::Down);
        let down = RouteStatus {
            state: "down",
            engine: Some(active.engine),
            model: Some(active.model.clone()),
            ..base.clone()
        };
        match &st.last {
            Some(Err(_)) => down,
            Some(Ok(d)) if is_down(d.target.engine) => down,
            Some(Ok(d)) => RouteStatus {
                state: if d.reason == Reason::EngineDown {
                    "fallback"
                } else {
                    "local"
                },
                engine: Some(d.target.engine),
                model: Some(d.target.model.clone()),
                reason: Some(d.reason.as_str()),
                ..base
            },
            None if is_down(active.engine) => down,
            None => RouteStatus {
                state: "local",
                ..down
            },
        }
    }

    /// Probes the active engine at once, then every `MONITOR_PERIOD` and after each config push, so the
    /// status is current when no request arrives.
    pub fn spawn_monitor(self: Arc<Self>) {
        tokio::spawn(async move {
            loop {
                let engine = self.lock().active().map(|a| a.engine);
                if let Some(k) = engine {
                    self.probe_health(k).await;
                }
                tokio::select! {
                    _ = self.clock.sleep(MONITOR_PERIOD) => {}
                    _ = self.wake.notified() => {}
                }
            }
        });
    }
}
