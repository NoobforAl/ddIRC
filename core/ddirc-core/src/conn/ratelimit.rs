//! Client-side flood protection, in both directions.
//!
//! Outgoing: IRC servers disconnect clients that send too fast, so we pace our
//! own traffic rather than relying on the server to be forgiving.
//!
//! Incoming: a malicious or misbehaving server can stream messages faster than
//! the UI can render them. Left unchecked that grows the event queue without
//! bound and wedges the app. We drop the excess and count it, so the UI can
//! honestly report "N messages dropped" instead of freezing.
//!
//! Both directions use the same token bucket. `Instant` is passed in rather than
//! read from the clock so the behaviour is testable without sleeping.

use std::time::{Duration, Instant};

/// A classic token bucket: `capacity` tokens available in a burst, refilling at
/// `refill_per_sec` sustained.
#[derive(Debug, Clone)]
pub struct TokenBucket {
    capacity: f64,
    tokens: f64,
    refill_per_sec: f64,
    last_refill: Instant,
}

impl TokenBucket {
    /// Create a bucket that starts full.
    ///
    /// # Panics
    /// Panics if `capacity` is zero or `refill_per_sec` is not positive; both
    /// would make the bucket permanently empty, which is a programming error
    /// rather than a runtime condition.
    pub fn new(capacity: u32, refill_per_sec: f64, now: Instant) -> Self {
        assert!(capacity > 0, "token bucket capacity must be positive");
        assert!(
            refill_per_sec > 0.0 && refill_per_sec.is_finite(),
            "token bucket refill rate must be positive and finite"
        );
        Self {
            capacity: f64::from(capacity),
            tokens: f64::from(capacity),
            refill_per_sec,
            last_refill: now,
        }
    }

    /// Add the tokens accrued since the last update.
    fn refill(&mut self, now: Instant) {
        // `saturating_duration_since` guards against a non-monotonic clock.
        let elapsed = now
            .saturating_duration_since(self.last_refill)
            .as_secs_f64();
        if elapsed > 0.0 {
            self.tokens = (self.tokens + elapsed * self.refill_per_sec).min(self.capacity);
            self.last_refill = now;
        }
    }

    /// Consume one token if available. Returns false when the caller should
    /// wait (outgoing) or drop (incoming).
    pub fn try_consume(&mut self, now: Instant) -> bool {
        self.refill(now);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }

    /// How long until a token is available. Zero if one already is.
    pub fn time_until_available(&mut self, now: Instant) -> Duration {
        self.refill(now);
        if self.tokens >= 1.0 {
            return Duration::ZERO;
        }
        Duration::from_secs_f64((1.0 - self.tokens) / self.refill_per_sec)
    }

    /// Tokens currently available, for diagnostics.
    pub fn available(&self) -> f64 {
        self.tokens
    }
}

/// Paces outgoing commands so the server does not disconnect us for flooding.
///
/// Defaults allow a short burst (useful when joining several channels at once)
/// then settle to one message every two seconds, which every mainstream ircd
/// tolerates.
#[derive(Debug, Clone)]
pub struct SendLimiter {
    bucket: TokenBucket,
}

impl SendLimiter {
    pub const DEFAULT_BURST: u32 = 5;
    pub const DEFAULT_PER_SEC: f64 = 0.5;

    pub fn new(now: Instant) -> Self {
        Self::with_rate(Self::DEFAULT_BURST, Self::DEFAULT_PER_SEC, now)
    }

    pub fn with_rate(burst: u32, per_sec: f64, now: Instant) -> Self {
        Self {
            bucket: TokenBucket::new(burst, per_sec, now),
        }
    }

    /// How long the caller must wait before sending. Zero means send now.
    ///
    /// On a zero result a token has been consumed; on a non-zero result nothing
    /// is consumed and the caller should sleep and ask again.
    pub fn acquire(&mut self, now: Instant) -> Duration {
        if self.bucket.try_consume(now) {
            Duration::ZERO
        } else {
            self.bucket.time_until_available(now)
        }
    }

    /// How long until a send would be permitted, without consuming anything.
    ///
    /// Used to arm a timer in the event loop, so waiting to send never stops us
    /// reading incoming messages.
    pub fn wait_time(&mut self, now: Instant) -> Duration {
        self.bucket.time_until_available(now)
    }
}

/// Caps how many incoming messages per second we will process, dropping and
/// counting the rest so a hostile server cannot exhaust memory or block the UI.
#[derive(Debug, Clone)]
pub struct ReceiveLimiter {
    bucket: TokenBucket,
    dropped: u64,
}

impl ReceiveLimiter {
    /// Generous enough that a busy channel or a netsplit burst is never
    /// affected, low enough to bound a deliberate flood.
    pub const DEFAULT_BURST: u32 = 200;
    pub const DEFAULT_PER_SEC: f64 = 50.0;

    pub fn new(now: Instant) -> Self {
        Self::with_rate(Self::DEFAULT_BURST, Self::DEFAULT_PER_SEC, now)
    }

    pub fn with_rate(burst: u32, per_sec: f64, now: Instant) -> Self {
        Self {
            bucket: TokenBucket::new(burst, per_sec, now),
            dropped: 0,
        }
    }

    /// True if this message should be processed; false if it was dropped.
    pub fn admit(&mut self, now: Instant) -> bool {
        if self.bucket.try_consume(now) {
            true
        } else {
            self.dropped = self.dropped.saturating_add(1);
            false
        }
    }

    /// Total messages dropped so far on this connection.
    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    /// Read and clear the drop counter, for periodic "N messages dropped"
    /// reporting without double-counting.
    pub fn take_dropped(&mut self) -> u64 {
        std::mem::take(&mut self.dropped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bucket_allows_a_full_burst_then_stops() {
        let t0 = Instant::now();
        let mut bucket = TokenBucket::new(5, 0.5, t0);

        for i in 0..5 {
            assert!(
                bucket.try_consume(t0),
                "burst token {i} should be available"
            );
        }
        assert!(!bucket.try_consume(t0), "burst should be exhausted");
    }

    #[test]
    fn bucket_refills_over_time() {
        let t0 = Instant::now();
        let mut bucket = TokenBucket::new(5, 0.5, t0);
        for _ in 0..5 {
            assert!(bucket.try_consume(t0));
        }

        // At 0.5/sec, two seconds buys exactly one token.
        assert!(!bucket.try_consume(t0 + Duration::from_millis(1999)));
        assert!(bucket.try_consume(t0 + Duration::from_secs(2)));
    }

    #[test]
    fn bucket_never_exceeds_capacity() {
        let t0 = Instant::now();
        let mut bucket = TokenBucket::new(5, 0.5, t0);
        // Idle for an hour; the bucket must not accumulate an unbounded burst.
        bucket.try_consume(t0 + Duration::from_secs(3600));
        assert!(bucket.available() <= 5.0);
    }

    #[test]
    fn time_until_available_is_accurate() {
        let t0 = Instant::now();
        let mut bucket = TokenBucket::new(1, 0.5, t0);
        assert!(bucket.try_consume(t0));

        let wait = bucket.time_until_available(t0);
        // One token at 0.5/sec takes two seconds.
        assert!(
            (wait.as_secs_f64() - 2.0).abs() < 0.01,
            "expected ~2s, got {wait:?}"
        );
    }

    #[test]
    fn time_until_available_is_zero_when_ready() {
        let t0 = Instant::now();
        let mut bucket = TokenBucket::new(2, 1.0, t0);
        assert_eq!(bucket.time_until_available(t0), Duration::ZERO);
    }

    #[test]
    fn clock_going_backwards_does_not_panic() {
        let t0 = Instant::now() + Duration::from_secs(10);
        let mut bucket = TokenBucket::new(2, 1.0, t0);
        // An earlier `now` must be treated as no elapsed time, not a negative.
        assert!(bucket.try_consume(t0 - Duration::from_secs(5)));
        assert!(bucket.available() <= 2.0);
    }

    #[test]
    fn send_limiter_reports_a_wait_once_burst_is_spent() {
        let t0 = Instant::now();
        let mut limiter = SendLimiter::with_rate(2, 1.0, t0);

        assert_eq!(limiter.acquire(t0), Duration::ZERO);
        assert_eq!(limiter.acquire(t0), Duration::ZERO);

        let wait = limiter.acquire(t0);
        assert!(wait > Duration::ZERO, "third send should be throttled");
        // Waiting the advised duration must actually let the send through.
        assert_eq!(limiter.acquire(t0 + wait), Duration::ZERO);
    }

    #[test]
    fn receive_limiter_drops_and_counts_the_excess() {
        let t0 = Instant::now();
        let mut limiter = ReceiveLimiter::with_rate(3, 1.0, t0);

        for _ in 0..3 {
            assert!(limiter.admit(t0));
        }
        assert!(!limiter.admit(t0), "beyond burst must be dropped");
        assert!(!limiter.admit(t0));
        assert_eq!(limiter.dropped(), 2);
    }

    #[test]
    fn take_dropped_clears_the_counter() {
        let t0 = Instant::now();
        let mut limiter = ReceiveLimiter::with_rate(1, 1.0, t0);
        assert!(limiter.admit(t0));
        assert!(!limiter.admit(t0));

        assert_eq!(limiter.take_dropped(), 1);
        assert_eq!(limiter.dropped(), 0, "counter should not double-report");
    }

    #[test]
    fn receive_limiter_recovers_after_a_flood() {
        let t0 = Instant::now();
        let mut limiter = ReceiveLimiter::with_rate(2, 10.0, t0);
        while limiter.admit(t0) {}

        // Normal traffic must resume once the flood stops.
        assert!(limiter.admit(t0 + Duration::from_millis(100)));
    }

    #[test]
    #[should_panic(expected = "capacity must be positive")]
    fn zero_capacity_is_rejected() {
        TokenBucket::new(0, 1.0, Instant::now());
    }

    #[test]
    #[should_panic(expected = "refill rate must be positive")]
    fn non_positive_refill_is_rejected() {
        TokenBucket::new(1, 0.0, Instant::now());
    }
}
