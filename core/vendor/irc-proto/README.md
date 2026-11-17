# `irc-proto` 1.1.0, with a limit on line length

The published crate, unmodified except for `src/line.rs`, which refuses a line
longer than `MAX_LINE_BYTES`. Upstream has no limit, so a server could exhaust the
client's memory by never sending a newline. The `irc` crate builds this codec
inside its own connection type, so it cannot be wrapped from outside.

Licensed under MPL-2.0 (see `LICENSE.md`), like the original at
<https://github.com/aatxe/irc>. The change is kept in this directory as source,
as the licence asks of a modified file.

Delete this directory and its line in `core/Cargo.toml`'s `[patch.crates-io]`
together when a release of the crate limits line length itself. The test
`a_line_with_no_end_is_refused_rather_than_held` in
`ddirc-core/src/conn/actor.rs` fails if the limit goes away without a replacement.
