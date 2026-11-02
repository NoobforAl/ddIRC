# ddIRC — guide for coding agents

A minimal chat client for IRC and XMPP. The repository root **is** a Flutter app
(`lib/`); the native engine is a Cargo workspace beside it (`core/`). Dart draws
the screen, Rust speaks the protocols, and `flutter_rust_bridge` joins them.

This file is the short version. Read the area guide for the part you are about to
change **before editing it**:

| Touching | Read first |
|---|---|
| anything under `lib/`, `test/`, `tool/` (the Flutter app) | [`lib/CLAUDE.md`](lib/CLAUDE.md) |
| anything under `core/` (the Rust workspace) | [`core/CLAUDE.md`](core/CLAUDE.md) |

Then go deeper only if the task needs it:

| You need to know | Read |
|---|---|
| how the pieces fit, and why Rust and not C | [`docs/architecture.md`](docs/architecture.md) |
| what the app promises about privacy, transport, secrets | [`SECURITY.md`](SECURITY.md), [`docs/privacy.md`](docs/privacy.md) |
| how CI is laid out, how the test servers work | [`docs/testing.md`](docs/testing.md) |
| how to build for a platform | [`docs/building.md`](docs/building.md) |
| what a feature is meant to do | [`docs/features.md`](docs/features.md) |
| the terminal client | [`docs/cli.md`](docs/cli.md) |

## Use `make`, not the underlying commands

**Every routine task has a `make` target. Use it. Do not run `flutter analyze`,
`flutter test`, `dart format`, `cargo test`, `cargo clippy` or `cargo fmt`
yourself.**

The targets exist because the bare commands are almost right and quietly
different from what CI runs: clippy without `--workspace --all-targets -D
warnings` passes code CI rejects; `dart format` without `--set-exit-if-changed`
reports nothing; `cargo` without `--manifest-path core/Cargo.toml` fails from the
root. CI calls the same targets, so a green `make` is a green pipeline.
`make help` lists them all.

| To | Run |
|---|---|
| format, auto-fix, then lint — **run this last, before you finish** | `make fix` |
| check only, change nothing (what CI runs) | `make lint` |
| run every hermetic test (Dart + Rust, no network, no Docker) | `make test` |
| check dependencies: advisories, licences, sources (needs network) | `make deny` |
| measure coverage (what CI sends to Codecov) | `make coverage` |
| regenerate the Dart bindings after changing `core/ddirc-bridge/src/api/` | `make codegen` |
| redraw app icons after changing `lib/src/ui/mark_spec.dart` | `make icons` |
| see which dependencies are outdated (changes nothing) | `make outdated` |
| run the app on Windows with hot reload | `make dev` |
| debug build / release build (Windows) | `make build` / `make build-release` |
| Android debug / release APK | `make build-android` / `make build-android-release` |

To run **one** test while iterating, a narrower direct command is fine
(`cargo test --manifest-path core/Cargo.toml -p ddirc-core <name>`, or
`flutter test test/<file>_test.dart`). Finish with `make fix` and `make test`
anyway; a narrow pass proves nothing about the rest.

### Integration tests need a server

They are `#[ignore]`d so `make test` stays hermetic. They talk to a real server in
Docker, so start it first:

| Suite | Start the server | Then run |
|---|---|---|
| IRC (ergo) | `make dev-server` | `make test-integration` |
| XMPP (ejabberd) | `make dev-xmpp` | `make test-integration-xmpp` |

`make dev-server-stop` / `dev-xmpp-stop` stop them; `dev-server-clean` also throws
the state away. Run these when a change touches the connection path.

### If `make` cannot find a tool

Flutter is looked up on `PATH`, then `~/flutter/bin`. Override with
`make fix FLUTTER=/path/to/flutter/bin/flutter`. On Windows the Makefile pins Git
Bash for its recipes (WSL's `bash.exe` would otherwise be picked up and fail with
a baffling path error); run `make` from Git Bash, PowerShell or cmd, and write
shell in recipes and scripts as POSIX.

## Rules that are easy to break

- **Never hand-edit generated code.** `lib/src/rust/**` and
  `core/ddirc-bridge/src/frb_generated.rs` come from `make codegen`. Change the Rust
  API, regenerate, commit both. `flutter_rust_bridge` (the Rust crate, the Dart
  package and the generated bindings) is bumped by hand and **together**; Dependabot
  is told to leave it alone.
- **Privacy and security promises are load-bearing.** `SECURITY.md` says what the
  app does and does not send, and a change that quietly breaks one is the one kind
  that gets reverted. In particular the `irc` crate's `ctcp` feature stays **off**
  (it makes the client answer strangers with the user's real name and local time —
  see the comment in `core/Cargo.toml`), TLS is verified, and credentials only ever
  go through `lib/src/model/secrets.dart`.
- **Add dependencies reluctantly.** The posture and the reasons are in
  [`docs/architecture.md`](docs/architecture.md#dependency-posture). `rusqlite` is
  capped by `arti`; arti's crates move together.
- **Do not silence a lint to get green.** Fix the code. If an exception is genuinely
  right, `#[allow]` / `// ignore:` it at the narrowest scope with a sentence on why.
  Do not widen `clippy` to `pedantic` or turn the analyzer rules off.
- **Do not leave the tree dirty after a lockfile change.** If `core/Cargo.lock`
  moves, run `make deny`; a new advisory ignore needs a written reason in
  `core/deny.toml`.

## House style

- **Comments say why.** This codebase comments the reason, the trade-off and the
  failure it prevents, usually at length, and rarely what the line does. Match
  that. A decision that looks arbitrary and is not deserves its paragraph.
- **A change arrives explained.** Be able to say what each hunk does and what would
  break without it (see [`CONTRIBUTING.md`](CONTRIBUTING.md)).
- **Commits** use Conventional Commits: `feat(xmpp): …`, `fix: …`, `perf(xmpp): …`,
  `test: …`, `ci: …`, `chore(lint): …`, `build(deps): …`. Subject says what and why;
  the body says what was measured.
- **Line endings.** Files in the working tree may be CRLF (Windows, `autocrlf`). Do
  not convert a file; edit in place so the diff stays the lines you changed.
  Shell scripts and `linux/installer/*` are LF (`.gitattributes`).

## CI in one paragraph

`.github/workflows/ci.yml` is the only entry point: `changes` → `lint` and `test`
(and `coverage`, beside them) → `build` → `ci`. A documentation-only change runs
nothing. Lint, Test, Coverage and Build are reusable workflows that never start on
their own. **`ci` is the single required check.** Actions are pinned by commit SHA
with the version in a trailing comment; Rust and Flutter versions are pinned once in
`.github/actions/setup/action.yml`. Coverage is a report and does not gate the
build. Details: [`docs/testing.md`](docs/testing.md#continuous-integration).
