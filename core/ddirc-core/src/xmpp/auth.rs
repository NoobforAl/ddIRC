//! Which login mechanisms this client will use.
//!
//! `tokio-xmpp` tries SCRAM-SHA-256, SCRAM-SHA-1, PLAIN and then ANONYMOUS, in
//! that order, taking the first the server offers. Two things about that need a
//! decision of ours rather than the library's.
//!
//! **ANONYMOUS is never acceptable.** It is a way to get a temporary account
//! with no password. A server that offers it to a client that supplied a
//! password, and not the mechanism that checks the password, would log the
//! client in as nobody and report success, and every message after that would
//! be sent as an account the user never chose. It is removed from what the
//! server advertised before the library sees it, so the library cannot reach
//! for it.
//!
//! **PLAIN is acceptable only because TLS is.** It sends the password itself.
//! That is the same trade the IRC side makes with SASL PLAIN, over a connection
//! that has already verified the server's certificate against the account's
//! domain; it is not offered by this module over anything else, because there
//! is nothing else. SCRAM is preferred whenever the server has it, so the
//! password is not handed to a server that can prove it knows the verifier.

use std::collections::BTreeSet;

/// The mechanisms this client is willing to use, strongest first. The order is
/// the library's; it is listed here so a reader does not have to take that on
/// trust.
pub const ACCEPTED: &[&str] = &["SCRAM-SHA-256", "SCRAM-SHA-1", "PLAIN"];

/// Reduce what a server advertised to what this client accepts.
///
/// Empty means there is nothing to log in with, and the caller should say so
/// rather than let the library report "no mechanism" without saying which.
pub fn acceptable(advertised: &BTreeSet<String>) -> BTreeSet<String> {
    advertised
        .iter()
        .filter(|mechanism| ACCEPTED.contains(&mechanism.as_str()))
        .cloned()
        .collect()
}

/// What the server offered, for an error message that says why login was
/// impossible.
pub fn describe(advertised: &BTreeSet<String>) -> String {
    if advertised.is_empty() {
        "none".to_owned()
    } else {
        advertised.iter().cloned().collect::<Vec<_>>().join(", ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(items: &[&str]) -> BTreeSet<String> {
        items.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn anonymous_is_removed_even_when_it_is_all_there_is() {
        assert!(acceptable(&set(&["ANONYMOUS"])).is_empty());
        assert_eq!(
            acceptable(&set(&["ANONYMOUS", "SCRAM-SHA-1"])),
            set(&["SCRAM-SHA-1"])
        );
    }

    #[test]
    fn mechanisms_that_send_nothing_we_can_check_are_dropped() {
        // EXTERNAL needs a client certificate, which nothing here has; the
        // -PLUS variants need channel binding the library does not offer them.
        let offered = set(&[
            "EXTERNAL",
            "SCRAM-SHA-1-PLUS",
            "SCRAM-SHA-256-PLUS",
            "PLAIN",
        ]);
        assert_eq!(acceptable(&offered), set(&["PLAIN"]));
    }

    #[test]
    fn the_strong_mechanisms_are_kept_alongside_plain() {
        let offered = set(&["PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-1"]);
        assert_eq!(acceptable(&offered), offered);
    }

    #[test]
    fn an_empty_offer_is_described_as_none() {
        assert_eq!(describe(&BTreeSet::new()), "none");
        assert_eq!(describe(&set(&["B", "A"])), "A, B");
    }
}
