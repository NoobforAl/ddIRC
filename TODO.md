# TODO

Only what is **not** done. Anything finished has been deleted from this file —
the reasoning behind a shipped decision lives in the source that carries it out,
and `git log` has the rest.

Everything here ships **disabled by default**. Items marked **beta** should
additionally be labelled as such in the UI.

Ordered by size, smallest first, except where one thing blocks another.

## 1. Bugs

### 1.1 Capability negotiation can wait forever

Found while fixing the away state, and left because it is not new — but it is
now on one more path than it was.

`SaslNegotiator` sends `CAP LS 302` and waits, and there is no timer anywhere:
no registration deadline in `conn/actor.rs`, nothing bounding how long
negotiation may take. A server that opens a connection and never answers a
`CAP` command holds the client until its own ping timeout, or forever if it
does not have one, showing "Registering" the whole time.

That was already true of every connection, since `CAP LS` has always been
unconditional, and true of the whole SASL exchange for anyone with credentials.
What changed is that a connection with no credentials now sends `CAP REQ` too,
where before it went straight to `CAP END`. Same failure, one more place to
meet it.

The fix is a deadline on registration — the local server has one and this does
not, which is the wrong way round, since the local server is the one talking to
a client the app wrote. On expiry the honest move is to abandon negotiation,
send `CAP END`, and let registration proceed unauthenticated rather than to
drop the connection.

## 2. Built-in Tor — beta

Built and working: `arti-client` 0.45 wrapped in `irc-core/ddirc-tor/`, reached
through the SOCKS5 proxy path the app already had. What is left is not code.

1. **Confirm the upstream report.** The stall that stopped this working is in
   `saturating-time` 0.4.0 and is fixed in the vendored copy at
   `irc-core/vendor/saturating-time/`, patched in through `[patch.crates-io]`.
   The source there says "Reported upstream"; this file used to say reporting
   was still to do. One of the two is stale — find out which, and if nothing was
   sent, send it: the no-dependency reproduction and the one-condition patch are
   what to send, to `saturating-time` and to arti as the consumer that makes it
   visible.
2. **Delete the vendored crate and the `[patch.crates-io]` block together** when
   a fixed release exists. Nothing else in this workspace depends on the crate
   directly.
3. **Run it in the app.** Everything measured so far was measured through
   `cargo test`, and both end-to-end tests are `#[ignore]`d. Nobody has yet
   switched Tor on in a running ddIRC and watched a network connect through it.
4. **A timed bootstrap on a platform that is not Windows**, for comparison. Not
   blocking anything — 14.3 s cold is already usable, and the failure that was
   fixed could not have happened on Linux at all.

## 3. A local IRC server — beta

Built, reachable, and covered by 24 tests that need neither Docker nor a
network. What is left:

1. **Run it.** Nobody has switched it on in a running app and talked to
   themselves. That is the one thing between this and done.
2. **Publish it as an onion service**, which is the real answer to "reachable
   from another machine" and the reason the listener stays loopback-only.
   Handing another machine a trust anchor to install is the control this
   codebase has refused to build, and a routable address, NAT traversal and a
   free port are three things an app cannot arrange. An onion service answers
   all of it: the address is the key, NAT stops mattering, and Tor authenticates
   which service answered. `arti-client` carries an `onion-service-service`
   feature for exactly this, and the bundled Tor now works, so this is unblocked and
   merely unbuilt.

## 4. Sending media — beta

The decision is settled — **DCC** — and the first piece is built: the core parses
a `DCC SEND` offer and emits `FileOffered` rather than answering it, and the
switch that allows any of it asks before it will turn on. Nothing is sent back
and no connection is made.

Metadata stripping is built and separable, and is done: `media/` removes EXIF,
XMP, IPTC, text chunks, comments, thumbnails and timestamps from JPEG, PNG, GIF
and WebP with the pixels byte-identical, `clean_media` crosses the FFI, and
`MediaCleaner` holds the policy. It has a preference, defaulting to on, and
deliberately **no settings switch**: a control that says "before sending" in an
app that cannot send would promise something that is not there. It gets one when
the send path lands — not before.

### What is left

1. **Settle what DCC does while Tor is on.** This is the question that shapes
   everything else. A DCC offer names an address and port for the other side to
   dial, which is the whole objection to DCC — and bundled Tor is the answer to
   it, if the design says how. The three candidates are a reverse DCC, an onion
   service per transfer, or refusing to offer DCC at all while Tor is on. The
   settings section currently says plainly that a transfer does not go through
   Tor, which is honest but is not an answer.
2. **Accepting an offer** — connecting, or listening for a reverse one, and
   writing the file where the user chose under the name already made safe. The
   settings copy currently says in as many words that this is not built; that
   sentence comes out when it is.
3. **Sending**, which is where the address question becomes unavoidable, and
   where the metadata switch earns its place.
4. **The UI for a transfer in flight** — progress that can be seen and a
   transfer that can be cancelled, without the chunk traffic appearing as chat.

### The framing, once there is a connection to put it on

Most of the original chat-message specification carries over; what changes is
that it stops being chat and becomes a framing over the direct connection, where
the 400-character cap (`MAX_MESSAGE_CHARS`) and the send limiter do not apply and
the 128 MB ceiling becomes reasonable rather than absurd. It was absurd before:
base64 turns 128 MB into ~179 M characters, ~447,000 chunks, about ten days at
the rate a server will tolerate — a 200 KB avatar took 23 minutes.

Handshake, sender first: `transfer_id`, `version`, `filename`, `size`,
`mime_type`, `hash`, `hash_algorithm`, `chunk_size`, `total_chunks`, `encoding`,
`encoded_size`. A fast hash rather than a cryptographic one — BLAKE3 or xxHash —
since this detects corruption rather than tampering.

Transfer: acknowledge each chunk; re-send a failed one; stop after 5 failures in
either direction; an acknowledgement not seen within 10 seconds is a failure;
128 MB maximum.

Two open questions, both about the shape rather than the decision:

- The original note said `expected file: xxx`, whose meaning is not clear — the
  filename after decoding, or the expected type. Worth settling before it is
  written into a `version: 1`.
- "Hide this progress on UI" — no progress indicator at all, or only that the
  raw protocol messages must not appear as chat lines? A transfer with no
  visible progress and no way to cancel is hard to tell apart from the app
  having frozen. Item 4 above assumes the second reading.
