//! XMPP, beside IRC rather than inside it.
//!
//! The same shape as [`crate::conn`], on purpose, so that someone who can read
//! one can read the other: a [`config`] that is validated before anything is
//! dialled, a [`connector`] that owns the transport, and an actor that owns the
//! stream and reports what happens as the same [`crate::api::events::IrcEvent`]
//! the IRC side does. Nothing here touches `conn`, and nothing in `conn` knows
//! this exists.
//!
//! What is shared is what was never about IRC to begin with: the proxy, the
//! backoff, the rate limits, the message store.

pub mod actor;
pub mod auth;
pub mod config;
pub mod connector;
pub mod diagnose;
pub mod session;
pub mod state;
