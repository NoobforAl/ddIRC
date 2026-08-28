//! DCC: sending files over a direct connection rather than as chat.
//!
//! # Why not as chat
//!
//! Because the arithmetic does not work. Outgoing messages are capped at 400
//! characters and the send limiter sustains half a message per second, which
//! is roughly what servers tolerate before treating a client as flooding.
//! Base64 turns 128 MB into about 447,000 messages — ten days, before counting
//! a single acknowledgement, and a 200 KB avatar still takes twenty minutes.
//! Chat is not a transport for files at any rate a server will accept.
//!
//! DCC is what the rest of IRC does instead: negotiate in the channel, then
//! open a TCP connection between the two clients and send over that, where no
//! message rate limit applies. It is also what other clients implement, so a
//! transfer works with people who are not using ddIRC.
//!
//! # What is here
//!
//! [`offer`] reads an offer, which was built first on purpose: an offer is a
//! string written by someone else, and the first thing to get right is not
//! being harmed by one. [`transfer`] moves the bytes — accepting an offer,
//! serving a file, and the address rule below that decides which of those is
//! allowed to happen.
//!
//! # The address problem, which bundled Tor changes
//!
//! A normal DCC offer names an address and a port for the other side to dial,
//! which means telling them where you are. That was always DCC's worst
//! property, and in an app whose proxy setting can be "route everything
//! through Tor" it would be worse than a weakness: it would be the file
//! transfer quietly undoing the setting.
//!
//! The protocol already has the shape of an answer. A **reverse** offer —
//! port `0` and a token — asks the *receiver* to listen, so the sender gives
//! out no address at all. It exists for senders behind NAT, and someone behind
//! Tor is behind the strongest NAT there is.
//!
//! The answer, now settled, is one rule: **a transfer discloses no more than
//! the connection that negotiated it.** With no proxy, offers name an address
//! and transfers dial it. With a proxy, nothing of ours is ever advertised —
//! an incoming offer is dialled *through* the proxy, and anything that would
//! require us to listen is refused with a reason rather than performed
//! quietly. [`transfer`] has the four cases in full.
//!
//! What that leaves undone is the sending half behind a proxy, which wants a
//! reverse offer of our own and the token round-trip that goes with it.
//! Sending is refused there rather than falling back to a direct offer,
//! because a fallback is exactly the thing the rule exists to prevent.

pub mod offer;
pub mod transfer;

pub use offer::{safe_filename, DccOffer};
pub use transfer::{TransferError, TransferEvent};
