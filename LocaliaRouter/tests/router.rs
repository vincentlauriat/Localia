mod common;

use async_trait::async_trait;
use common::*;
use localia_router::config::{RoutingConfig, TargetSpec};
use localia_router::engine::EngineKind;
use localia_router::router::{
    Clock, EngineHealth, Probe, Reason, RouteError, Router, LOAD_GRACE, MONITOR_PERIOD,
};
use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::net::TcpListener;
use tokio::sync::watch;

use EngineKind::{LlamaCpp, Mlx, Ollama};

// MARK: - Fakes

/// A clock that only moves when the test calls `advance`; `sleep` waits for that.
struct ManualClock {
    base: Instant,
    offset: watch::Sender<Duration>,
}

impl ManualClock {
    fn new() -> Arc<Self> {
        Arc::new(ManualClock {
            base: Instant::now(),
            offset: watch::channel(Duration::ZERO).0,
        })
    }

    fn advance(&self, d: Duration) {
        self.offset.send_modify(|o| *o += d);
    }

    fn elapsed(&self) -> Duration {
        *self.offset.borrow()
    }
}

#[async_trait]
impl Clock for ManualClock {
    fn now(&self) -> Instant {
        self.base + *self.offset.borrow()
    }

    async fn sleep(&self, d: Duration) {
        let target = *self.offset.borrow() + d;
        let mut rx = self.offset.subscribe();
        let _ = rx.wait_for(|o| *o >= target).await;
    }
}

/// Scripted engine states: a queue of answers per engine, then a steady state.
#[derive(Default)]
struct FakeProbe {
    steady: Mutex<HashMap<EngineKind, EngineHealth>>,
    script: Mutex<HashMap<EngineKind, VecDeque<EngineHealth>>>,
    listed: Mutex<HashMap<EngineKind, Vec<String>>>,
    health_calls: AtomicUsize,
}

impl FakeProbe {
    fn new() -> Arc<Self> {
        Arc::new(FakeProbe::default())
    }

    fn set(&self, k: EngineKind, h: EngineHealth) {
        self.steady.lock().unwrap().insert(k, h);
    }

    fn script(&self, k: EngineKind, seq: &[EngineHealth]) {
        self.script
            .lock()
            .unwrap()
            .insert(k, seq.iter().copied().collect());
    }

    fn list(&self, k: EngineKind, models: &[&str]) {
        self.listed
            .lock()
            .unwrap()
            .insert(k, models.iter().map(|m| m.to_string()).collect());
    }

    fn calls(&self) -> usize {
        self.health_calls.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl Probe for FakeProbe {
    async fn health(&self, k: EngineKind) -> EngineHealth {
        self.health_calls.fetch_add(1, Ordering::SeqCst);
        if let Some(h) = self
            .script
            .lock()
            .unwrap()
            .get_mut(&k)
            .and_then(|q| q.pop_front())
        {
            return h;
        }
        self.steady
            .lock()
            .unwrap()
            .get(&k)
            .copied()
            .unwrap_or(EngineHealth::Down)
    }

    async fn listed(&self, k: EngineKind, model: &str) -> bool {
        self.listed
            .lock()
            .unwrap()
            .get(&k)
            .is_some_and(|v| v.iter().any(|m| m == model))
    }
}

fn target(engine: EngineKind, model: &str, context_tokens: u32) -> TargetSpec {
    TargetSpec {
        engine,
        model: model.into(),
        context_tokens,
    }
}

fn routing(active: TargetSpec, equivalents: Vec<TargetSpec>) -> Option<RoutingConfig> {
    Some(RoutingConfig {
        active: Some(active),
        equivalents,
        mlx_model: None,
    })
}

fn router(
    probe: &Arc<FakeProbe>,
    clock: &Arc<ManualClock>,
    cfg: Option<RoutingConfig>,
) -> Arc<Router> {
    Arc::new(Router::new(probe.clone(), clock.clone(), cfg))
}

/// The usual pair: qwen on Ollama (65536), its equivalent on llama.cpp.
fn ollama_with_llama_equivalent(llama_ctx: u32) -> Option<RoutingConfig> {
    routing(
        target(Ollama, "qwen3:8b", 65536),
        vec![target(LlamaCpp, "qwen3-8b", llama_ctx)],
    )
}

/// Runs `fut` while advancing the manual clock by `step` until it finishes.
async fn drive<T: Send + 'static>(
    clock: &ManualClock,
    step: Duration,
    fut: impl std::future::Future<Output = T> + Send + 'static,
) -> T {
    let handle = tokio::spawn(fut);
    for _ in 0..10_000 {
        if handle.is_finished() {
            return handle.await.unwrap();
        }
        for _ in 0..4 {
            tokio::task::yield_now().await;
        }
        if handle.is_finished() {
            return handle.await.unwrap();
        }
        clock.advance(step);
    }
    panic!("the future never finished");
}

/// Yields until `cond` holds (bounded; no real time passes).
async fn until(mut cond: impl FnMut() -> bool) {
    for _ in 0..10_000 {
        if cond() {
            return;
        }
        tokio::task::yield_now().await;
    }
    panic!("condition never held");
}

// MARK: - Decisions

#[tokio::test]
async fn primary_up_is_primary() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    let d = r.decide(None).await.unwrap();
    assert_eq!(d.reason, Reason::Primary);
    assert_eq!(d.target, target(Ollama, "qwen3:8b", 65536));
    assert_eq!(d.reason.as_str(), "primary");
    let s = r.status();
    assert_eq!(s.state, "local");
    assert_eq!(s.engine, Some(Ollama));
    assert_eq!(s.model.as_deref(), Some("qwen3:8b"));
    assert_eq!(s.reason, Some("primary"));
}

#[tokio::test]
async fn router_falls_back_then_returns() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Down);
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));

    let d = r.decide(None).await.unwrap();
    assert_eq!(d.reason, Reason::EngineDown);
    assert_eq!(d.reason.as_str(), "engine-down");
    assert_eq!(d.target, target(LlamaCpp, "qwen3-8b", 65536));
    let s = r.status();
    assert_eq!(s.state, "fallback");
    assert_eq!(s.engine, Some(LlamaCpp));
    assert_eq!(s.reason, Some("engine-down"));

    probe.set(Ollama, EngineHealth::Up);
    let d = r.decide(None).await.unwrap();
    assert_eq!(d.reason, Reason::Primary);
    assert_eq!(d.target.engine, Ollama);
    assert_eq!(r.status().state, "local");
}

#[tokio::test]
async fn fallback_skips_smaller_window() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Down);
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(32768));
    assert_eq!(
        r.decide(Some(65536)).await.unwrap_err(),
        RouteError::Unavailable { engine: Ollama }
    );
    assert_eq!(r.status().state, "down");
    // A session declaring a window the equivalent holds may use it.
    assert_eq!(
        r.decide(Some(32768)).await.unwrap().reason,
        Reason::EngineDown
    );
}

#[tokio::test]
async fn declared_context_defaults_to_active_window() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Down);
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    let clock = ManualClock::new();
    // The active window is 65536: an equivalent with 32768 is too small when nothing is declared.
    let r = router(&probe, &clock, ollama_with_llama_equivalent(32768));
    assert_eq!(
        r.decide(None).await.unwrap_err(),
        RouteError::Unavailable { engine: Ollama }
    );
    // Same window as the active one: eligible.
    r.set_config(ollama_with_llama_equivalent(65536));
    assert_eq!(r.decide(None).await.unwrap().reason, Reason::EngineDown);
}

#[tokio::test]
async fn loading_primary_is_waited_for_then_used() {
    let probe = FakeProbe::new();
    probe.script(
        LlamaCpp,
        &[
            EngineHealth::Loading,
            EngineHealth::Loading,
            EngineHealth::Loading,
        ],
    );
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    let clock = ManualClock::new();
    let r = router(
        &probe,
        &clock,
        routing(
            target(LlamaCpp, "qwen3-8b", 65536),
            vec![target(Ollama, "qwen3:8b", 65536)],
        ),
    );
    let rr = r.clone();
    let d = drive(&clock, Duration::from_millis(500), async move {
        rr.decide(None).await
    })
    .await
    .unwrap();
    assert_eq!(d.reason, Reason::Primary);
    assert_eq!(d.target.engine, LlamaCpp);
    // Three Loading answers, then Up on the fourth; polled every 500 ms.
    assert_eq!(probe.calls(), 4);
    assert_eq!(clock.elapsed(), Duration::from_millis(1500));
}

#[tokio::test]
async fn loading_past_grace_falls_back() {
    let probe = FakeProbe::new();
    probe.set(LlamaCpp, EngineHealth::Loading);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    let clock = ManualClock::new();
    let r = router(
        &probe,
        &clock,
        routing(
            target(LlamaCpp, "qwen3-8b", 65536),
            vec![target(Ollama, "qwen3:8b", 65536)],
        ),
    );
    let rr = r.clone();
    let d = drive(&clock, Duration::from_millis(500), async move {
        rr.decide(None).await
    })
    .await
    .unwrap();
    assert_eq!(d.reason, Reason::EngineDown);
    assert_eq!(d.target.engine, Ollama);
    assert!(clock.elapsed() >= LOAD_GRACE, "{:?}", clock.elapsed());
    assert!(
        clock.elapsed() < LOAD_GRACE + Duration::from_secs(1),
        "{:?}",
        clock.elapsed()
    );
}

#[tokio::test]
async fn single_model_engine_needs_model_listed() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Down);
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(LlamaCpp, &["another-model"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    assert_eq!(
        r.decide(None).await.unwrap_err(),
        RouteError::Unavailable { engine: Ollama }
    );
    // An Ollama primary that is up but does not list the model is not used either.
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["llama3:8b"]);
    assert!(r.decide(None).await.is_err());
    probe.list(Ollama, &["qwen3:8b"]);
    assert_eq!(r.decide(None).await.unwrap().reason, Reason::Primary);
}

#[tokio::test]
async fn mlx_eligible_only_when_config_names_model() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Down);
    probe.set(Mlx, EngineHealth::Up);
    let clock = ManualClock::new();
    let mut cfg = RoutingConfig {
        active: Some(target(Ollama, "qwen3:8b", 65536)),
        equivalents: vec![target(Mlx, "mlx-community/Qwen3-8B-4bit", 65536)],
        mlx_model: Some("mlx-community/Other-4bit".into()),
    };
    let r = router(&probe, &clock, Some(cfg.clone()));
    assert!(r.decide(None).await.is_err());

    cfg.mlx_model = Some("mlx-community/Qwen3-8B-4bit".into());
    r.set_config(Some(cfg.clone()));
    let d = r.decide(None).await.unwrap();
    assert_eq!(d.reason, Reason::EngineDown);
    assert_eq!(d.target.engine, Mlx);

    cfg.mlx_model = None;
    r.set_config(Some(cfg));
    assert!(r.decide(None).await.is_err());
}

#[tokio::test]
async fn no_active_model_is_error_and_idle() {
    let probe = FakeProbe::new();
    let clock = ManualClock::new();
    let r = router(&probe, &clock, None);
    assert_eq!(r.status().state, "idle");
    assert_eq!(r.decide(None).await.unwrap_err(), RouteError::NoActiveModel);
    let s = r.status();
    assert_eq!(s.state, "idle");
    assert_eq!(s.engine, None);
    assert_eq!(s.model, None);
    assert_eq!(s.reason, None);

    r.set_config(Some(RoutingConfig {
        active: None,
        equivalents: vec![],
        mlx_model: None,
    }));
    assert_eq!(r.decide(None).await.unwrap_err(), RouteError::NoActiveModel);
    assert_eq!(r.status().state, "idle");
    assert_eq!(probe.calls(), 0);
}

// MARK: - Speed

#[tokio::test]
async fn speed_turns_slow_after_three_and_ok_after_two() {
    let probe = FakeProbe::new();
    let clock = ManualClock::new();
    let primary = target(Ollama, "qwen3:8b", 65536);
    let r = router(&probe, &clock, routing(primary.clone(), vec![]));
    assert_eq!(r.status().speed, "unknown");
    // 100 tokens in 5 s = 20 tok/s.
    r.record_decode_speed(&primary, 100, 5_000);
    assert_eq!(r.status().speed, "ok");
    // 100 tokens in 25 s = 4 tok/s: slow only after three in a row.
    r.record_decode_speed(&primary, 100, 25_000);
    r.record_decode_speed(&primary, 100, 25_000);
    assert_eq!(r.status().speed, "ok");
    r.record_decode_speed(&primary, 100, 25_000);
    assert_eq!(r.status().speed, "slow");
    // Back to ok after two good ones in a row (6.0 tok/s exactly counts as ok).
    r.record_decode_speed(&primary, 60, 10_000);
    assert_eq!(r.status().speed, "slow");
    r.record_decode_speed(&primary, 100, 25_000);
    r.record_decode_speed(&primary, 60, 10_000);
    assert_eq!(r.status().speed, "slow");
    r.record_decode_speed(&primary, 60, 10_000);
    assert_eq!(r.status().speed, "ok");

    // A change of primary resets the tracker.
    r.record_decode_speed(&primary, 100, 25_000);
    r.record_decode_speed(&primary, 100, 25_000);
    r.record_decode_speed(&primary, 100, 25_000);
    assert_eq!(r.status().speed, "slow");
    r.set_config(routing(target(LlamaCpp, "qwen3-8b", 65536), vec![]));
    assert_eq!(r.status().speed, "unknown");
}

#[tokio::test]
async fn speed_ignores_short_or_unknown_outputs() {
    let probe = FakeProbe::new();
    let clock = ManualClock::new();
    let primary = target(Ollama, "qwen3:8b", 65536);
    let r = router(&probe, &clock, routing(primary.clone(), vec![]));
    // Under 20 output tokens, or no decode time: not a sample.
    for _ in 0..5 {
        r.record_decode_speed(&primary, 19, 60_000);
        r.record_decode_speed(&primary, 0, 60_000);
        r.record_decode_speed(&primary, 500, 0);
    }
    assert_eq!(r.status().speed, "unknown");
    // A fallback target's speed is not the primary's.
    let other = target(LlamaCpp, "qwen3-8b", 65536);
    for _ in 0..5 {
        r.record_decode_speed(&other, 100, 25_000);
    }
    assert_eq!(r.status().speed, "unknown");
}

#[tokio::test]
async fn speed_never_changes_the_decision() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    let primary = target(Ollama, "qwen3:8b", 65536);
    for _ in 0..5 {
        r.record_decode_speed(&primary, 100, 60_000);
    }
    assert_eq!(r.status().speed, "slow");
    let d = r.decide(None).await.unwrap();
    assert_eq!(d.reason, Reason::Primary);
    assert_eq!(d.target, primary);
}

// MARK: - Status, monitor, stream failures

#[tokio::test]
async fn monitor_shows_down_without_requests() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    r.clone().spawn_monitor();
    // The first probe runs at once.
    until(|| probe.calls() >= 1).await;
    assert_eq!(r.status().state, "local");

    probe.set(Ollama, EngineHealth::Down);
    let before = probe.calls();
    clock.advance(MONITOR_PERIOD);
    until(|| r.status().state == "down").await;
    // Only the monitor probed: one more call, no request made.
    assert_eq!(probe.calls(), before + 1);

    // And it sees the engine come back.
    probe.set(Ollama, EngineHealth::Up);
    clock.advance(MONITOR_PERIOD);
    until(|| r.status().state == "local").await;
}

/// Falls back from a stopped Ollama to llama.cpp, with the monitor running.
async fn fallen_back_with_monitor() -> (Arc<FakeProbe>, Arc<ManualClock>, Arc<Router>) {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Down);
    probe.set(LlamaCpp, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    probe.list(LlamaCpp, &["qwen3-8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    assert_eq!(r.decide(None).await.unwrap().reason, Reason::EngineDown);
    r.clone().spawn_monitor();
    // The monitor's first round runs at once.
    let calls = probe.calls();
    until(|| probe.calls() > calls).await;
    for _ in 0..8 {
        tokio::task::yield_now().await;
    }
    assert_eq!(r.status().state, "fallback");
    (probe, clock, r)
}

#[tokio::test]
async fn monitor_returns_status_to_local_when_primary_is_back() {
    let (probe, clock, r) = fallen_back_with_monitor().await;
    probe.set(Ollama, EngineHealth::Up);
    clock.advance(MONITOR_PERIOD);
    until(|| r.status().state == "local").await;
    let s = r.status();
    assert_eq!(s.engine, Some(Ollama));
    assert_eq!(s.model.as_deref(), Some("qwen3:8b"));
    assert_eq!(s.reason, None);
}

#[tokio::test]
async fn monitor_shows_down_when_fallback_target_dies() {
    let (probe, clock, r) = fallen_back_with_monitor().await;
    probe.set(LlamaCpp, EngineHealth::Down);
    clock.advance(MONITOR_PERIOD);
    until(|| r.status().state == "down").await;
    let s = r.status();
    assert_eq!(s.engine, Some(Ollama));
    assert_eq!(s.model.as_deref(), Some("qwen3:8b"));
}

#[tokio::test]
async fn mark_down_shows_down_at_once() {
    let probe = FakeProbe::new();
    probe.set(Ollama, EngineHealth::Up);
    probe.list(Ollama, &["qwen3:8b"]);
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    r.decide(None).await.unwrap();
    assert_eq!(r.status().state, "local");
    r.mark_down(Ollama);
    assert_eq!(r.status().state, "down");
}

#[tokio::test]
async fn stream_failure_sets_engine_failure_until_success() {
    let probe = FakeProbe::new();
    let clock = ManualClock::new();
    let r = router(&probe, &clock, ollama_with_llama_equivalent(65536));
    assert_eq!(r.status().engine_failure, None);
    r.report_stream_failure(Mlx);
    assert_eq!(r.status().engine_failure, Some(Mlx));
    // Another engine's success does not clear it.
    r.report_stream_success(Ollama);
    assert_eq!(r.status().engine_failure, Some(Mlx));
    r.report_stream_success(Mlx);
    assert_eq!(r.status().engine_failure, None);
}

#[tokio::test]
async fn route_status_serializes_camel_case() {
    let probe = FakeProbe::new();
    let clock = ManualClock::new();
    let r = router(&probe, &clock, None);
    r.report_stream_failure(LlamaCpp);
    let j = serde_json::to_value(r.status()).unwrap();
    assert_eq!(
        j,
        serde_json::json!({
            "state": "idle", "engine": null, "model": null, "reason": null,
            "speed": "unknown", "engineFailure": "llamaCpp"
        })
    );
}

// MARK: - Through the server

const CONFIG_PUSH: &str = r#"{"logContent":false,"retentionDays":7,"routing":{"active":{"engine":"ollama","model":"qwen3:8b","contextTokens":65536},"equivalents":[]}}"#;

/// A port with nothing listening on it.
async fn closed_port() -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    l.local_addr().unwrap().port()
}

async fn route_of(port: u16) -> serde_json::Value {
    let r = send(port, "GET", "/localia/health", &[], b"").await;
    assert_eq!(r.status, 200);
    r.json()["route"].clone()
}

#[tokio::test]
async fn health_includes_route_status() {
    let dead = closed_port().await;
    let h = spawn(|c| {
        c.engine_ports.ollama = dead;
    })
    .await;
    let route = route_of(h.port).await;
    assert_eq!(route["state"], "idle");
    assert_eq!(route["speed"], "unknown");
    assert_eq!(route["engineFailure"], serde_json::Value::Null);

    // The config push updates routing live: the monitor probes the new primary, which is stopped.
    let r = send(
        h.port,
        "POST",
        "/localia/config",
        &[
            ("x-localia-token", TOKEN),
            ("Content-Type", "application/json"),
        ],
        CONFIG_PUSH.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 204);
    let mut route = route_of(h.port).await;
    for _ in 0..100 {
        if route["state"] == "down" {
            break;
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
        route = route_of(h.port).await;
    }
    assert_eq!(route["state"], "down", "{route}");
    assert_eq!(route["engine"], "ollama");
    assert_eq!(route["model"], "qwen3:8b");
}

#[tokio::test]
async fn health_never_awaits_probe() {
    // An engine that accepts connections and never answers.
    let stub = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let stub_port = stub.local_addr().unwrap().port();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((s, _)) = stub.accept().await {
            held.push(s);
        }
    });
    let h = spawn(|c| {
        c.engine_ports.ollama = stub_port;
    })
    .await;
    let r = send(
        h.port,
        "POST",
        "/localia/config",
        &[("x-localia-token", TOKEN)],
        CONFIG_PUSH.as_bytes(),
    )
    .await;
    assert_eq!(r.status, 204);
    for _ in 0..3 {
        let start = std::time::Instant::now();
        let route = route_of(h.port).await;
        let took = start.elapsed();
        assert!(took < Duration::from_millis(200), "health took {took:?}");
        assert_eq!(route["model"], "qwen3:8b");
    }
}

// MARK: - HttpProbe against stub engines

/// A stub engine answering `(path, status, body)` routes; counts the requests it gets.
async fn stub_engine(routes: Vec<(&'static str, u16, &'static str)>) -> (u16, Arc<AtomicUsize>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let counter = hits.clone();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = l.accept().await {
            counter.fetch_add(1, Ordering::SeqCst);
            let routes = routes.clone();
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                let n = s.read(&mut buf).await.unwrap_or(0);
                let head = String::from_utf8_lossy(&buf[..n]).to_string();
                let path = head.split(' ').nth(1).unwrap_or("").to_string();
                let (status, body) = routes
                    .iter()
                    .find(|(p, _, _)| *p == path)
                    .map(|(_, s, b)| (*s, *b))
                    .unwrap_or((404, ""));
                let reply = format!(
                    "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = s.write_all(reply.as_bytes()).await;
            });
        }
    });
    (port, hits)
}

#[tokio::test]
async fn http_probe_reads_engine_states_and_lists() {
    use localia_router::router::HttpProbe;
    use localia_router::EnginePorts;
    let (ollama, ollama_hits) = stub_engine(vec![
        ("/api/version", 200, r#"{"version":"0.12.0"}"#),
        (
            "/api/tags",
            200,
            r#"{"models":[{"name":"qwen3:8b"},{"name":"llama3:8b"}]}"#,
        ),
    ])
    .await;
    let (llama, _) = stub_engine(vec![
        ("/health", 503, r#"{"error":{"message":"Loading model"}}"#),
        (
            "/v1/models",
            200,
            r#"{"object":"list","data":[{"id":"qwen3-8b"}]}"#,
        ),
    ])
    .await;
    let mlx = closed_port().await;
    let probe = HttpProbe::new(
        EnginePorts {
            ollama,
            llama_cpp: llama,
            mlx,
        },
        reqwest::Client::builder().no_proxy().build().unwrap(),
    );
    assert_eq!(probe.health(Ollama).await, EngineHealth::Up);
    assert_eq!(probe.health(LlamaCpp).await, EngineHealth::Loading);
    assert_eq!(probe.health(Mlx).await, EngineHealth::Down);
    assert!(probe.listed(Ollama, "qwen3:8b").await);
    assert!(!probe.listed(Ollama, "qwen3:14b").await);
    assert!(probe.listed(LlamaCpp, "qwen3-8b").await);
    assert!(!probe.listed(LlamaCpp, "qwen3:8b").await);
    // MLX is decided by the config, never probed.
    assert!(!probe.listed(Mlx, "default_model").await);

    // Cached for 2 s: asking again does not reach the engine; `forget` makes it ask again.
    let before = ollama_hits.load(Ordering::SeqCst);
    assert_eq!(probe.health(Ollama).await, EngineHealth::Up);
    assert!(probe.listed(Ollama, "qwen3:8b").await);
    assert_eq!(ollama_hits.load(Ordering::SeqCst), before);
    probe.forget(Ollama);
    assert_eq!(probe.health(Ollama).await, EngineHealth::Up);
    assert_eq!(ollama_hits.load(Ordering::SeqCst), before + 1);
}

#[tokio::test]
async fn http_probe_times_out_a_silent_engine() {
    use localia_router::router::{HttpProbe, PROBE_TIMEOUT};
    use localia_router::EnginePorts;
    let stub = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = stub.local_addr().unwrap().port();
    tokio::spawn(async move {
        let mut held = Vec::new();
        while let Ok((s, _)) = stub.accept().await {
            held.push(s);
        }
    });
    let probe = HttpProbe::new(
        EnginePorts {
            ollama: port,
            llama_cpp: port,
            mlx: port,
        },
        reqwest::Client::builder().no_proxy().build().unwrap(),
    );
    let start = std::time::Instant::now();
    assert_eq!(probe.health(Ollama).await, EngineHealth::Down);
    let took = start.elapsed();
    assert!(
        took >= PROBE_TIMEOUT && took < PROBE_TIMEOUT * 3,
        "{took:?}"
    );
}
