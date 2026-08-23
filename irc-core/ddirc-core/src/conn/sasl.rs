//! IRCv3 capability negotiation and SASL PLAIN authentication.
//!
//! The `irc` crate has no SASL support at all — its `identify()` sends `CAP END`
//! *before* `NICK`/`USER`, which closes negotiation before authentication could
//! ever happen. So we drive registration ourselves, and this module is the state
//! machine that does it.
//!
//! It is deliberately free of any I/O: [`SaslNegotiator::advance`] takes a parsed
//! message and returns the commands to send. That makes the whole exchange —
//! including every failure path a hostile server can force — testable without a
//! socket.
//!
//! The wire sequence, per the IRCv3 SASL specification:
//!
//! ```text
//! -> CAP LS 302
//! <- CAP * LS :sasl multi-prefix ...
//! -> CAP REQ sasl
//! <- CAP * ACK :sasl
//! -> AUTHENTICATE PLAIN
//! <- AUTHENTICATE +
//! -> AUTHENTICATE <base64 of "\0account\0password">
//! <- 903 :SASL authentication successful
//! -> CAP END
//! ```

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine as _;
use irc::proto::{CapSubCommand, Command, Message, Response};
use zeroize::Zeroizing;

/// A hostile server can stream `CAP LS *` continuation lines forever. Cap how
/// much capability text we will accumulate before abandoning negotiation.
const MAX_CAPABILITY_BYTES: usize = 8 * 1024;

/// SASL requires the base64 payload to be split into chunks of at most 400
/// bytes, with an empty chunk (`+`) terminating an exact multiple.
const AUTHENTICATE_CHUNK: usize = 400;

/// Credentials for SASL PLAIN.
///
/// The password is wrapped in [`Zeroizing`] so it is wiped from memory when the
/// negotiator is dropped, rather than lingering for the connection's lifetime.
#[derive(Clone)]
pub struct Credentials {
    /// The account name (SASL "authcid"), usually the NickServ account.
    pub account: String,
    pub password: Zeroizing<String>,
}

impl std::fmt::Debug for Credentials {
    /// Redacted so credentials cannot reach logs through a stray `{:?}`.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credentials")
            .field("account", &self.account)
            .field("password", &"<redacted>")
            .finish()
    }
}

/// How capability negotiation ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SaslOutcome {
    /// SASL completed; we are logged in to the account.
    Authenticated,
    /// Negotiation finished without attempting SASL — either no credentials
    /// were supplied or the server never offered the capability. Callers should
    /// fall back to NickServ.
    NotAttempted { reason: NotAttempted },
    /// The server actively refused the exchange. Callers should fall back to
    /// NickServ and surface a warning.
    Rejected { reason: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotAttempted {
    /// No credentials were configured for this server.
    NoCredentials,
    /// The server's capability list did not include `sasl`.
    Unsupported,
}

/// The commands to send in response to one incoming message, plus the outcome
/// if this message concluded negotiation.
#[derive(Debug, Default)]
#[must_use]
pub struct SaslStep {
    pub send: Vec<Command>,
    pub outcome: Option<SaslOutcome>,
}

impl SaslStep {
    fn nothing() -> Self {
        Self::default()
    }

    fn send(cmd: Command) -> Self {
        Self {
            send: vec![cmd],
            outcome: None,
        }
    }

    /// Conclude negotiation: end capability negotiation and report `outcome`.
    fn finish(outcome: SaslOutcome) -> Self {
        Self {
            send: vec![Command::CAP(None, CapSubCommand::END, None, None)],
            outcome: Some(outcome),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    /// Before `start()` has been called.
    New,
    /// Sent `CAP LS 302`, collecting the (possibly multi-line) reply.
    AwaitingCapabilities,
    /// Sent `CAP REQ sasl`, waiting for ACK or NAK.
    AwaitingAck,
    /// Sent `AUTHENTICATE PLAIN`, waiting for the `+` challenge.
    AwaitingChallenge,
    /// Sent the credentials, waiting for a 90x numeric.
    AwaitingResult,
    /// Negotiation is over. Every further message is ignored.
    Finished,
}

/// Drives capability negotiation and, when credentials are present, SASL PLAIN.
pub struct SaslNegotiator {
    state: State,
    credentials: Option<Credentials>,
    /// Capabilities accumulated across `CAP LS` continuation lines.
    offered: String,
}

impl SaslNegotiator {
    pub fn new(credentials: Option<Credentials>) -> Self {
        Self {
            state: State::New,
            credentials,
            offered: String::new(),
        }
    }

    /// True once negotiation has concluded, in either direction.
    pub fn is_finished(&self) -> bool {
        self.state == State::Finished
    }

    /// Begin negotiation. The returned command must be sent before `NICK`/`USER`.
    ///
    /// We request CAP version 302 so the server advertises values (and so a
    /// modern `CAP LS` is used rather than the legacy form).
    pub fn start(&mut self) -> Command {
        self.state = State::AwaitingCapabilities;
        Command::CAP(None, CapSubCommand::LS, Some("302".to_owned()), None)
    }

    /// Feed one incoming message through the state machine.
    pub fn advance(&mut self, message: &Message) -> SaslStep {
        // Once finished, ignore everything. Without this a server could replay a
        // late 903 and drive us back into an authenticating state.
        if self.state == State::Finished {
            return SaslStep::nothing();
        }

        match &message.command {
            Command::CAP(_, sub, arg, suffix) => {
                self.on_cap(*sub, arg.as_deref(), suffix.as_deref())
            }
            Command::AUTHENTICATE(payload) => self.on_authenticate(payload),
            Command::Response(response, args) => self.on_response(*response, args),
            _ => SaslStep::nothing(),
        }
    }

    fn on_cap(&mut self, sub: CapSubCommand, arg: Option<&str>, suffix: Option<&str>) -> SaslStep {
        // For `CAP * LS :a b c` the list lands in `arg`; for the continuation
        // form `CAP * LS * :a b c` it lands in `suffix` with `arg == "*"`.
        let payload = suffix.or(arg).unwrap_or_default();
        let more_to_come = suffix.is_some() && arg == Some("*");

        match sub {
            CapSubCommand::LS if self.state == State::AwaitingCapabilities => {
                if self.offered.len() + payload.len() > MAX_CAPABILITY_BYTES {
                    self.state = State::Finished;
                    return SaslStep::finish(SaslOutcome::Rejected {
                        reason: "server sent an oversized capability list".to_owned(),
                    });
                }
                if !self.offered.is_empty() {
                    self.offered.push(' ');
                }
                self.offered.push_str(payload);

                if more_to_come {
                    return SaslStep::nothing();
                }
                self.request_sasl_or_finish()
            }
            CapSubCommand::ACK if self.state == State::AwaitingAck => {
                if !contains_capability(payload, "sasl") {
                    // ACK for something we did not ask for; treat as refusal.
                    self.state = State::Finished;
                    return SaslStep::finish(SaslOutcome::Rejected {
                        reason: "server acknowledged unexpected capabilities".to_owned(),
                    });
                }
                self.state = State::AwaitingChallenge;
                SaslStep::send(Command::AUTHENTICATE("PLAIN".to_owned()))
            }
            CapSubCommand::NAK if self.state == State::AwaitingAck => {
                self.state = State::Finished;
                SaslStep::finish(SaslOutcome::Rejected {
                    reason: "server refused the sasl capability".to_owned(),
                })
            }
            _ => SaslStep::nothing(),
        }
    }

    /// Decide what to do once the full capability list is known.
    fn request_sasl_or_finish(&mut self) -> SaslStep {
        let Some(_) = self.credentials.as_ref() else {
            self.state = State::Finished;
            return SaslStep::finish(SaslOutcome::NotAttempted {
                reason: NotAttempted::NoCredentials,
            });
        };

        if !contains_capability(&self.offered, "sasl") {
            self.state = State::Finished;
            return SaslStep::finish(SaslOutcome::NotAttempted {
                reason: NotAttempted::Unsupported,
            });
        }

        self.state = State::AwaitingAck;
        SaslStep::send(Command::CAP(
            None,
            CapSubCommand::REQ,
            None,
            Some("sasl".to_owned()),
        ))
    }

    fn on_authenticate(&mut self, payload: &str) -> SaslStep {
        if self.state != State::AwaitingChallenge || payload.trim() != "+" {
            return SaslStep::nothing();
        }
        let Some(credentials) = self.credentials.as_ref() else {
            self.state = State::Finished;
            return SaslStep::finish(SaslOutcome::NotAttempted {
                reason: NotAttempted::NoCredentials,
            });
        };

        self.state = State::AwaitingResult;
        SaslStep {
            send: encode_plain(&credentials.account, &credentials.password),
            outcome: None,
        }
    }

    fn on_response(&mut self, response: Response, args: &[String]) -> SaslStep {
        match response {
            Response::RPL_SASLSUCCESS if self.state == State::AwaitingResult => {
                self.state = State::Finished;
                // Credentials are no longer needed; drop them so the password is
                // zeroized rather than held for the life of the connection.
                self.credentials = None;
                SaslStep::finish(SaslOutcome::Authenticated)
            }
            Response::ERR_SASLFAIL
            | Response::ERR_SASLTOOLONG
            | Response::ERR_SASLABORT
            | Response::ERR_SASLALREADY
            | Response::ERR_NICKLOCKED => {
                if self.state != State::AwaitingResult && self.state != State::AwaitingChallenge {
                    return SaslStep::nothing();
                }
                self.state = State::Finished;
                self.credentials = None;
                SaslStep::finish(SaslOutcome::Rejected {
                    reason: sasl_failure_reason(response, args),
                })
            }
            _ => SaslStep::nothing(),
        }
    }
}

/// Build the `AUTHENTICATE` command(s) carrying base64 `\0account\0password`.
///
/// Payloads longer than 400 bytes are chunked, and an exact multiple is
/// terminated with `AUTHENTICATE +` so the server knows the payload ended.
fn encode_plain(account: &str, password: &str) -> Vec<Command> {
    // Zeroizing so the assembled secret does not outlive this function.
    let raw = Zeroizing::new(format!("\0{account}\0{password}"));
    let encoded = Zeroizing::new(BASE64.encode(raw.as_bytes()));

    if encoded.is_empty() {
        return vec![Command::AUTHENTICATE("+".to_owned())];
    }

    let mut commands: Vec<Command> = encoded
        .as_bytes()
        .chunks(AUTHENTICATE_CHUNK)
        // Chunks of base64 are always valid UTF-8, so this cannot fail.
        .map(|chunk| Command::AUTHENTICATE(String::from_utf8_lossy(chunk).into_owned()))
        .collect();

    if encoded.len() % AUTHENTICATE_CHUNK == 0 {
        commands.push(Command::AUTHENTICATE("+".to_owned()));
    }
    commands
}

/// Case-insensitively test whether a space-separated capability list contains
/// `wanted`. Capability tokens may carry an `=value` suffix (CAP 302), and may
/// be prefixed with `-` or `~`, which we strip before comparing.
fn contains_capability(list: &str, wanted: &str) -> bool {
    list.split_whitespace().any(|token| {
        let token = token.trim_start_matches(['-', '~', '=']);
        let name = token.split('=').next().unwrap_or(token);
        name.eq_ignore_ascii_case(wanted)
    })
}

/// Extract a human-readable reason from a SASL failure numeric, falling back to
/// the numeric's own name. The server-supplied text is untrusted, so it is
/// length-bounded here; control characters are stripped downstream by
/// [`crate::text::format`] before it ever reaches the UI.
fn sasl_failure_reason(response: Response, args: &[String]) -> String {
    const MAX_REASON: usize = 200;
    let text = args
        .last()
        .map(String::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or("SASL authentication failed");

    let mut reason: String = text.chars().take(MAX_REASON).collect();
    if matches!(response, Response::ERR_NICKLOCKED) {
        reason.push_str(" (nick is account-locked)");
    }
    reason
}

#[cfg(test)]
mod tests {
    use super::*;

    fn creds() -> Credentials {
        Credentials {
            account: "ddirc".to_owned(),
            password: Zeroizing::new("hunter2".to_owned()),
        }
    }

    fn msg(raw: &str) -> Message {
        raw.parse().expect("test message should parse")
    }

    /// Run a negotiator up to the point where it has sent `AUTHENTICATE PLAIN`.
    fn negotiator_awaiting_challenge() -> SaslNegotiator {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let _ = n.advance(&msg("CAP * LS :sasl multi-prefix\r\n"));
        let _ = n.advance(&msg("CAP * ACK :sasl\r\n"));
        n
    }

    fn rendered(step: &SaslStep) -> Vec<String> {
        step.send.iter().map(String::from).collect()
    }

    #[test]
    fn start_requests_capability_version_302() {
        let mut n = SaslNegotiator::new(Some(creds()));
        assert_eq!(String::from(&n.start()).trim_end(), "CAP LS 302");
    }

    #[test]
    fn full_happy_path_authenticates() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();

        let step = n.advance(&msg("CAP * LS :sasl multi-prefix\r\n"));
        assert_eq!(rendered(&step)[0].trim_end(), "CAP REQ sasl");
        assert!(step.outcome.is_none());

        let step = n.advance(&msg("CAP * ACK :sasl\r\n"));
        assert_eq!(rendered(&step)[0].trim_end(), "AUTHENTICATE PLAIN");

        let step = n.advance(&msg("AUTHENTICATE +\r\n"));
        let expected = BASE64.encode("\0ddirc\0hunter2");
        assert_eq!(
            rendered(&step)[0].trim_end(),
            format!("AUTHENTICATE {expected}")
        );

        let step = n.advance(&msg(":srv 903 ddirc :SASL authentication successful\r\n"));
        assert_eq!(step.outcome, Some(SaslOutcome::Authenticated));
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
        assert!(n.is_finished());
    }

    #[test]
    fn multiline_capability_list_is_accumulated() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();

        // Continuation line: no decision yet, and nothing sent.
        let step = n.advance(&msg("CAP * LS * :multi-prefix away-notify\r\n"));
        assert!(step.send.is_empty());
        assert!(step.outcome.is_none());

        // `sasl` only appears in the final line.
        let step = n.advance(&msg("CAP * LS :sasl account-tag\r\n"));
        assert_eq!(rendered(&step)[0].trim_end(), "CAP REQ sasl");
    }

    #[test]
    fn missing_sasl_capability_ends_negotiation_cleanly() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let step = n.advance(&msg("CAP * LS :multi-prefix away-notify\r\n"));

        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::Unsupported
            })
        );
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
    }

    #[test]
    fn without_credentials_negotiation_ends_immediately() {
        let mut n = SaslNegotiator::new(None);
        n.start();
        let step = n.advance(&msg("CAP * LS :sasl\r\n"));

        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::NoCredentials
            })
        );
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
    }

    #[test]
    fn nak_is_reported_as_rejection() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let _ = n.advance(&msg("CAP * LS :sasl\r\n"));
        let step = n.advance(&msg("CAP * NAK :sasl\r\n"));

        assert!(matches!(step.outcome, Some(SaslOutcome::Rejected { .. })));
        assert!(n.is_finished());
    }

    #[test]
    fn authentication_failure_is_reported_with_server_reason() {
        let mut n = negotiator_awaiting_challenge();
        let _ = n.advance(&msg("AUTHENTICATE +\r\n"));
        let step = n.advance(&msg(":srv 904 ddirc :Invalid credentials\r\n"));

        match step.outcome {
            Some(SaslOutcome::Rejected { reason }) => assert_eq!(reason, "Invalid credentials"),
            other => panic!("expected rejection, got {other:?}"),
        }
        assert!(n.is_finished());
    }

    #[test]
    fn nick_locked_failure_is_annotated() {
        let mut n = negotiator_awaiting_challenge();
        let _ = n.advance(&msg("AUTHENTICATE +\r\n"));
        let step = n.advance(&msg(
            ":srv 902 ddirc :You must use a nick assigned to you\r\n",
        ));

        match step.outcome {
            Some(SaslOutcome::Rejected { reason }) => assert!(reason.contains("account-locked")),
            other => panic!("expected rejection, got {other:?}"),
        }
    }

    #[test]
    fn messages_after_completion_are_ignored() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let _ = n.advance(&msg("CAP * LS :sasl\r\n"));
        let _ = n.advance(&msg("CAP * ACK :sasl\r\n"));
        let _ = n.advance(&msg("AUTHENTICATE +\r\n"));
        let _ = n.advance(&msg(":srv 903 ddirc :ok\r\n"));

        // A replayed success (or anything else) must not restart the exchange.
        let step = n.advance(&msg(":srv 903 ddirc :ok\r\n"));
        assert!(step.send.is_empty());
        assert!(step.outcome.is_none());

        let step = n.advance(&msg("CAP * LS :sasl\r\n"));
        assert!(step.send.is_empty());
    }

    #[test]
    fn oversized_capability_list_aborts_negotiation() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();

        let flood = "x".repeat(4096);
        let mut outcome = None;
        // Each continuation line is legal on its own; the total is not.
        for _ in 0..4 {
            let step = n.advance(&msg(&format!("CAP * LS * :{flood}\r\n")));
            if step.outcome.is_some() {
                outcome = step.outcome;
                break;
            }
        }
        assert!(matches!(outcome, Some(SaslOutcome::Rejected { .. })));
        assert!(n.is_finished());
    }

    #[test]
    fn challenge_other_than_plus_is_ignored() {
        let mut n = negotiator_awaiting_challenge();
        // A server sending a real challenge means a mechanism we did not ask
        // for; we must not treat it as the go-ahead to send credentials.
        let step = n.advance(&msg("AUTHENTICATE Zm9v\r\n"));
        assert!(step.send.is_empty());
        assert!(!n.is_finished());
    }

    #[test]
    fn capability_matching_handles_values_and_prefixes() {
        assert!(contains_capability(
            "sasl=PLAIN,EXTERNAL multi-prefix",
            "sasl"
        ));
        assert!(contains_capability("multi-prefix SASL", "sasl"));
        assert!(!contains_capability("sasl-not-really multi-prefix", "sasl"));
        assert!(!contains_capability("", "sasl"));
    }

    #[test]
    fn long_credentials_are_chunked() {
        // A password long enough to exceed one AUTHENTICATE payload.
        let commands = encode_plain("account", &"p".repeat(500));
        assert!(commands.len() >= 2, "payload should span multiple commands");
        for cmd in &commands {
            let Command::AUTHENTICATE(payload) = cmd else {
                panic!("expected AUTHENTICATE");
            };
            assert!(payload.len() <= AUTHENTICATE_CHUNK);
        }
    }

    #[test]
    fn credentials_debug_does_not_leak_password() {
        let rendered = format!("{:?}", creds());
        assert!(!rendered.contains("hunter2"), "password leaked: {rendered}");
        assert!(rendered.contains("redacted"));
    }
}
