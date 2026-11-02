# Agent instructions

The instructions for coding agents live in [`CLAUDE.md`](CLAUDE.md), kept in one place so
the two cannot drift apart. Read it before doing anything. In short:

- Use the `make` targets (`make fix`, `make lint`, `make test`, `make deny`,
  `make coverage`, `make codegen`) rather than running `flutter`, `dart` or `cargo`
  directly for routine checks. `make help` lists them.
- Before changing the Flutter app, read [`lib/CLAUDE.md`](lib/CLAUDE.md). Before changing
  the Rust workspace, read [`core/CLAUDE.md`](core/CLAUDE.md).
- Never hand-edit generated code (`lib/src/rust/**`, `core/ddirc-bridge/src/frb_generated.rs`).
