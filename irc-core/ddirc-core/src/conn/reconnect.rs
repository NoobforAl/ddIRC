//! Reconnection backoff.
//!
//! Mobile clients lose connectivity constantly — a tunnel, a handoff between
//! Wi-Fi and cellular, a backgrounded app. Retrying immediately in a tight loop
//! burns battery and gets the user K-lined for reconnect flooding, so delays
//! grow exponentially up to a ceiling.
//!
//! Jitter is applied because it is not just politeness: without it, every client
//! disconnected by the same netsplit returns simultaneously, and the thundering
//! herd knocks the server over again.
//!
//! We use "equal jitter" — half the window plus a random draw over the other
//! half — rather than the more common "full jitter" that draws over the whole
//! interval. Full jitter can return a near-zero delay, which against a server
//! that is actively refusing us (a K-line, a DNSBL listing) produces a burst of
//! immediate retries that looks like an attack and invites escalation. Equal
//! jitter still spreads a herd, but guarantees the delay actually grows.

use std::time::Duration;

/// Exponential backoff with full jitter.
#[derive(Debug, Clone)]
pub struct Backoff {
    base: Duration,
    max: Duration,
    factor: f64,
    /// Number of consecutive failures so far.
    attempt: u32,
}

impl Default for Backoff {
    fn default() -> Self {
        Self::new(Duration::from_secs(2), Duration::from_secs(300), 2.0)
    }
}

impl Backoff {
    /// # Panics
    /// Panics if `factor` is not greater than 1.0, which would never grow the
    /// delay and so defeats the purpose.
    pub fn new(base: Duration, max: Duration, factor: f64) -> Self {
        assert!(
            factor > 1.0 && factor.is_finite(),
            "backoff factor must exceed 1.0"
        );
        Self {
            base,
            max,
            factor,
            attempt: 0,
        }
    }

    /// Consecutive failures recorded since the last [`reset`](Self::reset).
    pub fn attempt(&self) -> u32 {
        self.attempt
    }

    /// Clear the failure count. Call after a connection is fully established —
    /// specifically after registration completes, not merely after the socket
    /// opens, or a server that accepts then immediately drops us would reset the
    /// backoff on every cycle and produce a hot loop.
    pub fn reset(&mut self) {
        self.attempt = 0;
    }

    /// The uncapped-by-jitter ceiling for the current attempt.
    fn window(&self) -> Duration {
        let exponent = f64::from(self.attempt);
        let scaled = self.base.as_secs_f64() * self.factor.powf(exponent);

        // `powf` overflows to infinity for large attempt counts; comparing
        // against the max first keeps the conversion well defined.
        if !scaled.is_finite() || scaled >= self.max.as_secs_f64() {
            self.max
        } else {
            Duration::from_secs_f64(scaled)
        }
    }

    /// Record a failure and return how long to wait, using `jitter` in `[0, 1)`.
    ///
    /// Split out from [`next_delay`](Self::next_delay) so tests can pin the
    /// random draw and assert exact bounds.
    pub fn next_delay_with_jitter(&mut self, jitter: f64) -> Duration {
        debug_assert!((0.0..1.0).contains(&jitter), "jitter must be in [0, 1)");
        let window = self.window();
        self.attempt = self.attempt.saturating_add(1);

        // Equal jitter: always at least half the window, plus a random draw
        // over the remainder. Never returns a near-zero delay.
        let fraction = 0.5 + 0.5 * jitter.clamp(0.0, 1.0);
        Duration::from_secs_f64(window.as_secs_f64() * fraction)
    }

    /// Record a failure and return how long to wait before retrying.
    pub fn next_delay(&mut self) -> Duration {
        self.next_delay_with_jitter(rand::random::<f64>())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn backoff() -> Backoff {
        Backoff::new(Duration::from_secs(2), Duration::from_secs(300), 2.0)
    }

    #[test]
    fn window_doubles_each_attempt() {
        let mut b = backoff();
        // Jitter of 1.0 is clamped into range, giving the top of the window.
        let delays: Vec<f64> = (0..4)
            .map(|_| b.next_delay_with_jitter(0.999_999).as_secs_f64())
            .collect();

        assert!((delays[0] - 2.0).abs() < 0.01, "got {:?}", delays[0]);
        assert!((delays[1] - 4.0).abs() < 0.01, "got {:?}", delays[1]);
        assert!((delays[2] - 8.0).abs() < 0.01, "got {:?}", delays[2]);
        assert!((delays[3] - 16.0).abs() < 0.01, "got {:?}", delays[3]);
    }

    #[test]
    fn delay_is_capped_at_max() {
        let mut b = backoff();
        for _ in 0..50 {
            let delay = b.next_delay_with_jitter(0.999_999);
            assert!(
                delay <= Duration::from_secs(300),
                "exceeded ceiling: {delay:?}"
            );
        }
    }

    #[test]
    fn extreme_attempt_counts_do_not_overflow() {
        let mut b = backoff();
        // Drive the exponent far enough that `powf` reaches infinity.
        for _ in 0..2000 {
            let delay = b.next_delay_with_jitter(0.5);
            assert!(delay <= Duration::from_secs(300));
        }
        assert!(b.attempt() > 0);
    }

    #[test]
    fn jitter_spreads_delay_across_the_window() {
        // Same attempt number, different draws, must give different delays.
        let low = backoff().next_delay_with_jitter(0.1);
        let high = backoff().next_delay_with_jitter(0.9);
        assert!(
            low < high,
            "jitter should spread reconnections: {low:?} vs {high:?}"
        );
    }

    #[test]
    fn unluckiest_draw_still_waits_half_the_window() {
        // Regression: full jitter returned sub-second delays here, so a server
        // actively refusing us was retried almost immediately.
        let delay = backoff().next_delay_with_jitter(0.0);
        assert!(
            (delay.as_secs_f64() - 1.0).abs() < 0.01,
            "expected half of the 2s base window, got {delay:?}"
        );
    }

    #[test]
    fn every_draw_is_at_least_half_the_window() {
        let mut b = backoff();
        for attempt in 0..6 {
            let floor = 2.0_f64.powi(attempt) * 2.0 * 0.5;
            let delay = b.next_delay_with_jitter(0.0);
            assert!(
                delay.as_secs_f64() >= floor.min(300.0) - 0.01,
                "attempt {attempt}: {delay:?} below floor {floor}s"
            );
        }
    }

    #[test]
    fn reset_returns_to_the_base_window() {
        let mut b = backoff();
        for _ in 0..5 {
            b.next_delay_with_jitter(0.5);
        }
        assert_eq!(b.attempt(), 5);

        b.reset();
        assert_eq!(b.attempt(), 0);
        let delay = b.next_delay_with_jitter(0.999_999);
        assert!((delay.as_secs_f64() - 2.0).abs() < 0.01, "got {delay:?}");
    }

    #[test]
    fn random_delays_stay_within_bounds() {
        let mut b = backoff();
        for _ in 0..200 {
            let delay = b.next_delay();
            assert!(delay > Duration::ZERO && delay <= Duration::from_secs(300));
        }
    }

    #[test]
    #[should_panic(expected = "factor must exceed 1.0")]
    fn non_growing_factor_is_rejected() {
        Backoff::new(Duration::from_secs(1), Duration::from_secs(10), 1.0);
    }
}
