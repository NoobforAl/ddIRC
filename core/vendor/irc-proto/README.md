# `irc-proto` 1.1.0, with a limit on line length

The published crate, unmodified except for `src/line.rs`, which refuses a line
longer than `MAX_LINE_BYTES`. Upstream has no limit, so a server could exhaust the
client's memory by never sending a newline. The `irc` crate builds this codec
inside its own connection type, so it cannot be wrapped from outside.

One further edit in the same file, and not a change of behaviour: `LineCodec::new`
reads its `label` argument only when the crate's `encoding` feature is on, and this
build has it off, so the parameter was reported unused on every build. It is now
taken with a `let _ = label;` behind the same `cfg`. The signature is untouched,
because the `irc` crate calls it.

Licensed under MPL-2.0 (see `LICENSE.md`), like the original at
<https://github.com/aatxe/irc>. The change is kept in this directory as source,
as the licence asks of a modified file.

Delete this directory and its line in `core/Cargo.toml`'s `[patch.crates-io]`
together when a release of the crate limits line length itself. The test
`a_line_with_no_end_is_refused_rather_than_held` in
`ddirc-core/src/conn/actor.rs` fails if the limit goes away without a replacement.
