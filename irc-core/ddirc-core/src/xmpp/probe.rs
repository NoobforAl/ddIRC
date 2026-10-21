//! "Test connection" for an XMPP account.
//!
//! The counterpart of [`crate::conn::probe`]: the same journey a real
//! connection makes - proxy, TLS, the stream, the login - run once and
//! reported, so a wrong password is told to the person where they typed it
//! rather than discovered as an account that never comes online.
//!
//! It stops once the server has accepted the credentials. Binding a resource
//! and sending presence would announce the account to everyone who watches it,
//! and a test is not a reason to do that; nothing is joined, nothing is sent,
//! and the stream is closed.

use std::time::{Duration, Instant};

use tokio_xmpp::jid::Jid;

use crate::api::types::AuthOutcome;
use crate::conn::probe::ProbeReport;
use crate::xmpp::actor::{login, LoginError};
use crate::xmpp::config::XmppConfig;
use crate::xmpp::connector::DirectTlsConnector;
use crate::xmpp::diagnose;

/// How long the whole test may take. The same as the IRC side's, and for the
/// same reason: generous, because a Tor circuit is slow to build, and a limit
/// only to catch a server that has stopped answering.
const TIMEOUT: Duration = Duration::from_secs(60);

/// Connect, log in, report, disconnect.
///
/// The `Err` side is already a sentence for the user.
pub async fn probe(config: XmppConfig) -> Result<ProbeReport, String> {
    config.validate().map_err(|e| e.to_string())?;
    match tokio::time::timeout(TIMEOUT, attempt(&config)).await {
        Ok(result) => result,
        Err(_) => Err(format!(
            "{} did not finish logging in within {} seconds. The server may be down, or \
             slow to reach through the proxy.",
            config.dial_host().unwrap_or_default(),
            TIMEOUT.as_secs()
        )),
    }
}

async fn attempt(config: &XmppConfig) -> Result<ProbeReport, String> {
    let started = Instant::now();
    let connector = DirectTlsConnector::new(config).map_err(|e| e.to_string())?;
    let account = config.bare_jid().map_err(|e| e.to_string())?;
    let server = config.dial_host().map_err(|e| e.to_string())?;
    let jid = Jid::from(account.clone());

    let (_features, stream) = login(&connector, &jid, &config.password)
        .await
        .map_err(|error| match error {
            LoginError::Xmpp(e) => diagnose::explain(&e, &server).message,
            LoginError::NoMechanism(offered) => diagnose::no_acceptable_mechanism(&offered).message,
        })?;
    // Dropped without ceremony: the stream is not bound, so there is no
    // session for the server to tell anyone about.
    drop(stream);

    Ok(ProbeReport {
        nickname: account.to_string(),
        server: Some(account.domain().to_string()),
        auth: AuthOutcome::Sasl,
        elapsed_ms: started.elapsed().as_millis().try_into().unwrap_or(u64::MAX),
    })
}
