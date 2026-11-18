//! Decode speed of the primary target (Decision 8): measured and shown on health, never acted on in R1.

use std::collections::VecDeque;

/// Samples kept.
pub const WINDOW: usize = 5;
/// Fewer output tokens than this is too short to time.
pub const MIN_OUTPUT: u64 = 20;
/// Below this many tokens per second a sample is slow (`LocaliaConstants.simpleOKTPS`).
pub const SLOW_TPS: f64 = 6.0;
/// Consecutive slow samples that turn the state `slow`.
pub const TO_SLOW: usize = 3;
/// Consecutive good samples that turn it back to `ok`.
pub const TO_OK: usize = 2;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Speed {
    Unknown,
    Ok,
    Slow,
}

impl Speed {
    pub fn as_str(self) -> &'static str {
        match self {
            Speed::Unknown => "unknown",
            Speed::Ok => "ok",
            Speed::Slow => "slow",
        }
    }
}

/// The last `WINDOW` decode speeds and the state they give.
#[derive(Debug)]
pub struct SpeedTracker {
    samples: VecDeque<f64>,
    state: Speed,
}

impl Default for SpeedTracker {
    fn default() -> Self {
        SpeedTracker {
            samples: VecDeque::with_capacity(WINDOW),
            state: Speed::Unknown,
        }
    }
}

impl SpeedTracker {
    pub fn state(&self) -> Speed {
        self.state
    }

    pub fn reset(&mut self) {
        *self = SpeedTracker::default();
    }

    /// `output_tokens` decoded in `decode_ms` (end minus first content byte). Short or untimed answers are not
    /// samples.
    pub fn record(&mut self, output_tokens: u64, decode_ms: u64) {
        if output_tokens < MIN_OUTPUT || decode_ms == 0 {
            return;
        }
        let tps = output_tokens as f64 * 1000.0 / decode_ms as f64;
        if self.samples.len() == WINDOW {
            self.samples.pop_front();
        }
        self.samples.push_back(tps);
        let slow_run = self.trailing(|s| s < SLOW_TPS);
        let ok_run = self.trailing(|s| s >= SLOW_TPS);
        self.state = match self.state {
            _ if slow_run >= TO_SLOW => Speed::Slow,
            Speed::Slow if ok_run >= TO_OK => Speed::Ok,
            // The first good sample is enough to call an unmeasured target fine.
            Speed::Unknown if ok_run >= 1 => Speed::Ok,
            other => other,
        };
    }

    fn trailing(&self, pred: impl Fn(f64) -> bool) -> usize {
        self.samples.iter().rev().take_while(|s| pred(**s)).count()
    }
}
