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

/// Capabilities worth having that are not SASL, requested when offered.
///
/// Deliberately a short list, and every entry has to earn its place by being
/// something the client already does something with. `away-notify` is here
/// because the member list has an away state it can render and, without this,
/// no way of ever being told about one: away is not in `NAMES` and there is no
/// other unsolicited notification of it.
///
/// Nothing here changes registration. If a server offers none of them the
/// exchange is exactly what it was.
const EXTRA_CAPABILITIES: &[&str] = &["away-notify"];

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
    /// Whether the request that is in flight included `sasl`.
    ///
    /// A request can now carry capabilities that have nothing to do with
    /// authentication, so an ACK is no longer proof that SASL is about to
    /// start — and this is what tells the two apart.
    requested_sasl: bool,
    /// What to report if the exchange ends without SASL having been attempted.
    ///
    /// Decided when the capability list arrives rather than when negotiation
    /// ends, because that is the moment both halves of the answer are known:
    /// whether there were credentials, and whether the server offered `sasl`.
    without_sasl: NotAttempted,
}

impl SaslNegotiator {
    pub fn new(credentials: Option<Credentials>) -> Self {
        Self {
            state: State::New,
            credentials,
            offered: String::new(),
            requested_sasl: false,
            without_sasl: NotAttempted::NoCredentials,
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

    /// Give up on negotiation and close it, without waiting for the server.
    ///
    /// For the caller that has run out of patience: a server may answer `CAP LS`
    /// slowly, wrongly, or never, and this state machine has no clock of its own
    /// to notice. The commands returned end capability negotiation, so
    /// registration continues unauthenticated rather than stopping — an
    /// unanswered `CAP` is a reason to stop asking, not a reason to hang up.
    ///
    /// Reporting the outcome honestly is the whole difficulty. Past the
    /// capability list, `without_sasl` already holds the true answer for a
    /// connection that was never going to authenticate anyway; before it, the
    /// only thing known is whether there were credentials that now will not be
    /// used, which is a fallback to NickServ rather than an anonymous
    /// connection.
    pub fn abandon(&mut self) -> SaslStep {
        if self.state == State::Finished {
            return SaslStep::nothing();
        }

        let unanswered = matches!(self.state, State::New | State::AwaitingCapabilities);
        let outcome = if self.requested_sasl || (unanswered && self.credentials.is_some()) {
            SaslOutcome::Rejected {
                reason: "server did not finish capability negotiation in time".to_owned(),
            }
        } else {
            SaslOutcome::NotAttempted {
                reason: self.without_sasl,
            }
        };

        self.state = State::Finished;
        // Nothing further will be sent, so the password stops being needed here
        // exactly as it does on the paths that succeed or fail outright.
        self.credentials = None;
        SaslStep::finish(outcome)
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
                // An acknowledgement that is not about SASL ends negotiation
                // rather than starting an exchange. That is the ordinary case
                // for a server offering `away-notify` to a connection with no
                // credentials — the capability is on, and there was never
                // going to be an AUTHENTICATE.
                if !self.requested_sasl {
                    self.state = State::Finished;
                    return SaslStep::finish(SaslOutcome::NotAttempted {
                        reason: self.without_sasl,
                    });
                }
                if !contains_capability(payload, "sasl") {
                    // SASL was asked for and something else was granted. Not a
                    // capability set worth continuing on: the exchange about to
                    // start has not been agreed to.
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
                if !self.requested_sasl {
                    // Refusing a capability that was only ever a nicety is not
                    // a failure to report; nothing was going to depend on it.
                    return SaslStep::finish(SaslOutcome::NotAttempted {
                        reason: self.without_sasl,
                    });
                }
                SaslStep::finish(SaslOutcome::Rejected {
                    reason: "server refused the sasl capability".to_owned(),
                })
            }
            _ => SaslStep::nothing(),
        }
    }

    /// Decide what to do once the full capability list is known.
    fn request_sasl_or_finish(&mut self) -> SaslStep {
        // Why SASL is decided first: it is the only capability here whose
        // absence the caller has to act on, by falling back to NickServ. The
        // answer is settled now and carried, so that whichever way the request
        // below is answered, what is reported about authentication is the same
        // as it would have been before any of this existed.
        self.without_sasl = if self.credentials.is_none() {
            NotAttempted::NoCredentials
        } else {
            NotAttempted::Unsupported
        };
        self.requested_sasl =
            self.credentials.is_some() && contains_capability(&self.offered, "sasl");

        let mut wanted: Vec<&str> = Vec::new();
        if self.requested_sasl {
            wanted.push("sasl");
        }
        wanted.extend(
            EXTRA_CAPABILITIES
                .iter()
                .copied()
                .filter(|cap| contains_capability(&self.offered, cap)),
        );

        if wanted.is_empty() {
            self.state = State::Finished;
            return SaslStep::finish(SaslOutcome::NotAttempted {
                reason: self.without_sasl,
            });
        }

        self.state = State::AwaitingAck;
        SaslStep::send(Command::CAP(
            None,
            CapSubCommand::REQ,
            None,
            Some(wanted.join(" ")),
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

        // `sasl` only appears in the final line, and the request covers what
        // was offered across both — `away-notify` came from the first.
        let step = n.advance(&msg("CAP * LS :sasl account-tag\r\n"));
        assert_eq!(
            rendered(&step)[0].trim_end(),
            "CAP REQ :sasl away-notify",
            "sasl leads, and the accumulated list is what is asked for"
        );
    }

    #[test]
    fn missing_sasl_capability_still_takes_what_is_useful() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        // No `sasl`, so authentication is already decided — but `away-notify`
        // is worth having on its own, and asking for it costs one round trip.
        let step = n.advance(&msg("CAP * LS :multi-prefix away-notify\r\n"));
        assert_eq!(rendered(&step)[0].trim_end(), "CAP REQ away-notify");
        assert!(
            step.outcome.is_none(),
            "nothing is concluded until answered"
        );

        let step = n.advance(&msg("CAP * ACK :away-notify\r\n"));
        // The answer about authentication is the one it would always have
        // been: the server does not do SASL, so NickServ is the fallback.
        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::Unsupported
            })
        );
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
        assert!(n.is_finished());
    }

    #[test]
    fn a_refused_extra_is_not_reported_as_a_sasl_failure() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let _ = n.advance(&msg("CAP * LS :away-notify\r\n"));

        // Nothing depended on it, so a refusal is not a failure to report —
        // and it must not become one, or every server that says no to a
        // nicety would look like a server that refused to authenticate us.
        let step = n.advance(&msg("CAP * NAK :away-notify\r\n"));
        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::Unsupported
            })
        );
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
    }

    #[test]
    fn a_server_offering_nothing_we_want_ends_in_one_step() {
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let step = n.advance(&msg("CAP * LS :multi-prefix account-tag\r\n"));

        // No request at all, so no extra round trip against a server that has
        // nothing this client can use.
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
    fn away_notify_is_taken_without_credentials_and_says_so_correctly() {
        let mut n = SaslNegotiator::new(None);
        n.start();
        let step = n.advance(&msg("CAP * LS :sasl away-notify\r\n"));
        assert_eq!(rendered(&step)[0].trim_end(), "CAP REQ away-notify");

        // `sasl` is offered and deliberately not asked for: there is nothing
        // to authenticate with, and requesting it would start an exchange that
        // could only be abandoned.
        let step = n.advance(&msg("CAP * ACK :away-notify\r\n"));
        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::NoCredentials
            })
        );
    }

    #[test]
    fn abandoning_an_unanswered_cap_ls_closes_negotiation() {
        // The case the deadline exists for: `CAP LS 302` went out and the
        // server said nothing at all, ever.
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();

        let step = n.abandon();
        assert_eq!(
            rendered(&step)[0].trim_end(),
            "CAP END",
            "registration has to be let through, not left waiting"
        );
        assert!(n.is_finished());
        assert!(
            matches!(step.outcome, Some(SaslOutcome::Rejected { .. })),
            "credentials that went unused are a NickServ fallback, not an \
             anonymous connection"
        );
    }

    #[test]
    fn abandoning_without_credentials_is_not_reported_as_a_failure() {
        // Nothing was going to be authenticated here, so a silent server is
        // not a thing to warn anyone about — it is the ordinary outcome,
        // reached late.
        let mut n = SaslNegotiator::new(None);
        n.start();

        let step = n.abandon();
        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::NoCredentials
            })
        );
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
    }

    #[test]
    fn abandoning_mid_exchange_is_a_rejection() {
        // Asked for `sasl`, was granted it, and then the challenge never came.
        let mut n = negotiator_awaiting_challenge();

        let step = n.abandon();
        assert!(matches!(step.outcome, Some(SaslOutcome::Rejected { .. })));
        assert_eq!(rendered(&step)[0].trim_end(), "CAP END");
        assert!(n.is_finished());
    }

    #[test]
    fn abandoning_keeps_the_answer_it_already_had() {
        // Past the capability list the truth is already known: this server does
        // not do SASL. A timeout waiting for the `away-notify` acknowledgement
        // must not overwrite that with one about a deadline.
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let _ = n.advance(&msg("CAP * LS :away-notify\r\n"));

        let step = n.abandon();
        assert_eq!(
            step.outcome,
            Some(SaslOutcome::NotAttempted {
                reason: NotAttempted::Unsupported
            })
        );
    }

    #[test]
    fn abandoning_a_finished_negotiation_sends_nothing() {
        // The deadline may land on an exchange that has just completed. A
        // second `CAP END` after registration is a stray command to the server
        // and a second outcome to the UI; neither should happen.
        let mut n = SaslNegotiator::new(Some(creds()));
        n.start();
        let _ = n.advance(&msg("CAP * LS :multi-prefix\r\n"));
        assert!(n.is_finished());

        let step = n.abandon();
        assert!(step.send.is_empty());
        assert!(step.outcome.is_none());
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
