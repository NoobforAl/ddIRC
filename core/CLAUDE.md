# `core/` — the Rust workspace

Read [`../CLAUDE.md`](../CLAUDE.md) first for the `make` commands, which apply here
unchanged (run them from the repository root; the Makefile supplies
`--manifest-path core/Cargo.toml`). This file is only about the Rust side. For the
Flutter side see [`../lib/CLAUDE.md`](../lib/CLAUDE.md).

## The crates

| Crate | What it is | Depends on |
|---|---|---|
| `ddirc-core` | The reusable engine: IRC **and** XMPP, DCC file transfer, image metadata stripping, mIRC text formatting, the message store. **No knowledge of Flutter.** `#![forbid(unsafe_code)]`. | — |
| `ddirc-bridge` | The `flutter_rust_bridge` binding crate (`cdylib` + `staticlib`). Owns every type that crosses into Dart, in `src/api/`. `src/frb_generated.rs` is generated. | core, tor, server |
| `ddirc-server` | The local IRC server: loopback only, TLS only. Deliberately separate so nothing shipped can reach it by accident. | core |
| `ddirc-tor` | Bundled Tor (`arti`) behind a loopback SOCKS5 port. About 500 crates, kept behind one door so the rest builds without them. | core |
| `ddirc-cli` | Terminal client and server, full-screen or plain lines. A second consumer of `ddirc-core`, which keeps the core honest. | core |

The dependency direction matters. Nothing in `ddirc-core` may name a Flutter or bridge
type, and no `irc`-crate type may escape `ddirc-core::api`. `vendor/saturating-time`
is a deliberate patch (see the comment at `[patch.crates-io]` in `Cargo.toml`); do not
upgrade around it, and delete it only together with that block.

`ddirc-core` module map and the reasoning behind it:
[`../docs/architecture.md`](../docs/architecture.md#core-modules). Skim it before
adding a module.

## How the code is shaped

- **Actors own sockets.** `conn/actor.rs` (IRC) and `xmpp/actor.rs` (XMPP) are single
  tokio tasks with no shared mutable state. Everything else around them is
  **pure state machines**: stanzas/lines in, events and outgoing data out, with no
  socket and no clock (`conn/sasl.rs`, `xmpp/session.rs`, `xmpp/session/features.rs`,
  `ddirc-server/src/state.rs`). New protocol logic goes in the pure part, so it can be
  tested by feeding it input directly.
- **One event type, one command type.** IRC and XMPP report through the same
  `IrcEvent` and take the same `ClientCommand`. A new feature adds to those shared
  types (and the bridge) rather than forking a protocol-specific path; a protocol that
  cannot do something answers with an error that says so.
- **Bound everything the network can make you hold.** Rooms, rosters, presence, the
  edit index, uploads: every collection fed by a remote party has a cap, and the perf
  tests assert memory does not grow with traffic. An unbounded `Vec` or `HashMap`
  fed from the wire is a bug.
- **Treat every remote string as hostile.** A `DCC SEND` offer, a filename, an HTTP
  Upload slot, a JID, a server-supplied message are all written by a stranger.
  Validate before acting (`dcc/offer.rs`, `xmpp/upload.rs`); a filename never becomes
  a path unsanitised; an upload slot must be `https`, carry no credentials and name a
  host, not an address.
- **XMPP does not use `tokio-xmpp`'s own client** (it retries every failure forever,
  wrong passwords included). The login and the reconnect policy are ours in
  `xmpp/actor.rs`; only the stream is the library's. See `SECURITY.md#xmpp`.
- **Never enable the `irc` crate's `ctcp` feature.** It auto-answers strangers with
  the user's real name and local time. The reason is spelled out in `Cargo.toml`.

## Lints

`core/Cargo.toml` defines `[workspace.lints.rust]` and `[workspace.lints.clippy]`; every
crate opts in with `[lints] workspace = true`. A new crate must do the same. `make
lint` runs clippy with `-D warnings`, so a warning is a failure.

- A curated set, not `clippy::pedantic`. Do not add pedantic wholesale; add a single lint
  only if the tree already passes it or you fix every hit in the same change.
- Generated `frb_generated.rs` trips some lints (`unimplemented`,
  `undocumented_unsafe_blocks`, `unit_bindings`), which is why those are not enabled.
- Fix the code. If an `#[allow]` is right, scope it narrowly and say why in a comment.
- `cargo clippy --fix` (via `make fix`) handles the mechanical hits; it can change many
  files, so review the diff.

`make deny` checks `Cargo.lock` against `core/deny.toml` (advisories, yanked releases,
licences, sources). After `cargo update`, run it. Every ignored advisory carries its
reason; add one only with a real reason.

## Testing

`make test` runs the whole workspace, hermetically. Where tests live:

- **Unit tests** sit in the file they test, in `#[cfg(test)] mod tests` (the XMPP session
  keeps a large one in `xmpp/session/tests.rs`).
- **Transcript tests** drive the real dispatch path with scripted server output; add
  one for any wire-level bug, written to fail before the fix.
- **`ddirc-server/tests/round_trip.rs`** starts the real server and connects the real
  client over real TLS, including a guard that the connection is *refused* without the
  trust anchor. Keep that guard working.
- **Integration suites** in `ddirc-core/tests/` (`dev_server.rs`, `dev_xmpp.rs`) are
  `#[ignore]`d and need Docker: `make dev-server` + `make test-integration`, and
  `make dev-xmpp` + `make test-integration-xmpp`. A real server found bugs the scripted
  ones could not, so run them when you touch the connection or login path. The XMPP
  ones run `--test-threads=1` (they share two accounts).
- **Perf and memory** (`xmpp_perf.rs`, `sort_bench.rs`) are `#[ignore]`d and run in
  release mode; the command is in [`../docs/testing.md`](../docs/testing.md#memory-and-speed).
  Run it when you change how a session stores or indexes anything.

A bug fix ships with the test that would have caught it.

## After changing the bridge API

Edit `ddirc-bridge/src/api/*`, run `make codegen`, then `make test` (the Dart tests fake
the generated API, so they break loudly if a signature moved). Commit the regenerated
Dart under `lib/src/rust/` and `frb_generated.rs` with the change. Keep the Rust crate,
the Dart package and the generated code on the same `flutter_rust_bridge` version.

## Documents for this area

[`../docs/architecture.md`](../docs/architecture.md), [`../docs/testing.md`](../docs/testing.md),
[`../SECURITY.md`](../SECURITY.md), [`../docs/local-server.md`](../docs/local-server.md)
(the dev servers), [`../docs/cli.md`](../docs/cli.md).
