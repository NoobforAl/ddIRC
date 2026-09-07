//! One connection made in order to be reported on, and then thrown away.
//!
//! The network editor can save a server and find out whether it works only by
//! connecting to it for real, which means the first sign of a typo, a wrong
//! port, a firewall or a rejected password is a session that sits at
//! "Reconnecting" in the corner of the screen. This is the same journey — TCP,
//! the proxy if there is one, TLS, capability negotiation, SASL, registration —
//! run once, on purpose, with an answer at the end of it.
//!
//! Deliberately *not* a shortcut. A probe that only opened a socket would say
//! "works" for a server that will refuse the password, and a probe that skipped
//! TLS would say "works" for a certificate this machine does not trust. It
//! dials through [`crate::conn::actor::irc_config`], which is the same
//! configuration the real connection uses, so anything this accepts the actor
//! will accept for the same reasons.
//!
//! What it does not do is anything a connection would be remembered for. No
//! channel is joined, no NickServ password is sent, and it quits as soon as the
//! server says hello — a test that left the user idling in five channels would
//! be a test with a side effect nobody asked for.

use std::time::{Duration, Instant};

use futures_util::StreamExt;
use irc::client::Client;
use irc::proto::{Command as Irc, Response};

use crate::api::types::{AuthOutcome, ServerConfig};
use crate::conn::actor::{irc_config, is_error_numeric};
use crate::conn::diagnose;
use crate::conn::sasl::{Credentials, NotAttempted, SaslNegotiator, SaslOutcome};
use crate::text::format;

/// How long the whole probe may take.
///
/// The same 30 seconds capability negotiation is given inside a real
/// connection, because it is bounded by the same thing: a server that has
/// stopped answering. Long enough that a slow network or a Tor circuit is not
/// mistaken for a broken server, short enough that a button does not appear
/// stuck.
pub const TIMEOUT: Duration = Duration::from_secs(30);

/// What a probe found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeReport {
    /// The nickname the server actually gave us.
    ///
    /// Worth reporting rather than echoing back what was asked for: a server
    /// that truncated it, or handed over an alternate because the first was
    /// taken, has told the user something they would otherwise discover later.
    pub nickname: String,

    /// How the server introduced itself, when it named itself at all.
    pub server: Option<String>,

    /// Whether the configured credentials were accepted.
    pub auth: AuthOutcome,

    /// How long the whole exchange took, so a server that works but is a long
    /// way away can say so.
    pub elapsed_ms: u64,
}

/// Connect, register, report, disconnect.
///
/// The error is a finished sentence for the user, not a debug string: every
/// failure below either comes from [`diagnose`], which names the host and says
/// what usually fixes it, or from the server's own words.
pub async fn probe(config: ServerConfig) -> Result<ProbeReport, String> {
    match tokio::time::timeout(TIMEOUT, attempt(&config)).await {
        Ok(result) => result,
        Err(_) => Err(format!(
            "{}:{} did not finish registering within {} seconds. The server \
             accepted the connection but never completed the handshake.",
            config.host,
            config.port,
            TIMEOUT.as_secs()
        )),
    }
}

async fn attempt(config: &ServerConfig) -> Result<ProbeReport, String> {
    config.validate().map_err(|e| e.to_string())?;

    let started = Instant::now();
    let mut client = Client::from_config(irc_config(config))
        .await
        .map_err(|e| diagnose::explain(&e, config))?;
    let mut stream = client.stream().map_err(|e| diagnose::explain(&e, config))?;
    let sender = client.sender();

    let mut sasl = SaslNegotiator::new(credentials(config));
    let mut auth = AuthOutcome::Anonymous;

    // The same registration burst the actor sends, in the same order, and
    // unthrottled for the same reason: servers expect it immediately.
    let send = |command| {
        sender
            .send(command)
            .map_err(|e| diagnose::explain(&e, config))
    };
    send(sasl.start())?;
    if let Some(password) = &config.server_password {
        send(Irc::PASS(password.as_str().to_owned()))?;
    }
    send(Irc::NICK(config.nickname.clone()))?;
    send(Irc::USER(
        config.username().to_owned(),
        "0".to_owned(),
        config.realname().to_owned(),
    ))?;

    // The last thing the server complained about.
    //
    // Held rather than reported at once, because most numerics in this range
    // are not fatal — a server that objects to something and carries on
    // registering us has not failed the test. It becomes the answer only if
    // registration never completes, which is the case where the server's own
    // words are the most useful thing anyone could be told.
    let mut complaint: Option<String> = None;

    while let Some(message) = stream.next().await {
        let message = message.map_err(|e| {
            complaint
                .clone()
                .unwrap_or_else(|| diagnose::explain(&e, config))
        })?;

        if !sasl.is_finished() {
            let step = sasl.advance(&message);
            for command in step.send {
                send(command)?;
            }
            if let Some(outcome) = step.outcome {
                auth = describe_auth(outcome, config);
            }
        }

        match &message.command {
            Irc::Response(Response::RPL_WELCOME, args) => {
                // Quit before returning: this connection exists to be reported
                // on and the user is not in it.
                let _ = sender.send(Irc::QUIT(Some("ddIRC connection test".to_owned())));
                return Ok(ProbeReport {
                    nickname: args
                        .first()
                        .cloned()
                        .unwrap_or_else(|| config.nickname.clone()),
                    server: message.prefix.as_ref().map(|p| p.to_string()),
                    auth,
                    elapsed_ms: started.elapsed().as_millis() as u64,
                });
            }
            Irc::ERROR(reason) => {
                return Err(format!("{}: {}", config.host, format::strip(reason)));
            }
            Irc::Response(response, args) if is_error_numeric(*response) => {
                complaint = Some(format::strip(
                    args.last()
                        .cloned()
                        .unwrap_or_else(|| format!("{response:?}"))
                        .as_str(),
                ));
            }
            _ => {}
        }
    }

    Err(complaint.unwrap_or_else(|| {
        format!(
            "{}:{} closed the connection before registration finished.",
            config.host, config.port
        )
    }))
}

fn credentials(config: &ServerConfig) -> Option<Credentials> {
    Some(Credentials {
        account: config.sasl_account.clone()?,
        password: config.sasl_password.clone()?,
    })
}

/// The same reading of a SASL result the actor takes, minus the part that acts
/// on it — nothing here sends a NickServ password.
fn describe_auth(outcome: SaslOutcome, config: &ServerConfig) -> AuthOutcome {
    match outcome {
        SaslOutcome::Authenticated => AuthOutcome::Sasl,
        SaslOutcome::NotAttempted {
            reason: NotAttempted::NoCredentials,
        } if config.nickserv_password.is_some() => AuthOutcome::NickServFallback {
            reason: "no SASL credentials configured".to_owned(),
        },
        SaslOutcome::NotAttempted {
            reason: NotAttempted::NoCredentials,
        } => AuthOutcome::Anonymous,
        SaslOutcome::NotAttempted {
            reason: NotAttempted::Unsupported,
        } => AuthOutcome::NickServFallback {
            reason: "server does not offer SASL".to_owned(),
        },
        SaslOutcome::Rejected { reason } => AuthOutcome::NickServFallback { reason },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn an_invalid_configuration_is_refused_before_anything_is_dialled() {
        let config = ServerConfig {
            host: String::new(),
            ..config_for("example.invalid")
        };
        let error = probe(config).await.unwrap_err();
        // The point is that it never left the machine: an empty host has no
        // socket to fail on, so this can only have come from validation.
        assert!(!error.is_empty(), "an empty host must be explained");
    }

    #[tokio::test]
    async fn a_host_that_does_not_resolve_names_itself() {
        let error = probe(config_for("ddirc-nonexistent.invalid"))
            .await
            .unwrap_err();
        assert!(
            error.contains("ddirc-nonexistent.invalid"),
            "the message has to say which server failed, got: {error}"
        );
    }

    fn config_for(host: &str) -> ServerConfig {
        ServerConfig {
            host: host.to_owned(),
            port: ServerConfig::DEFAULT_TLS_PORT,
            nickname: "probe".to_owned(),
            alt_nicks: Vec::new(),
            username: None,
            realname: None,
            channels: Vec::new(),
            sasl_account: None,
            sasl_password: None,
            nickserv_password: None,
            server_password: None,
            extra_root_cert: None,
            proxy: None,
        }
    }
}
