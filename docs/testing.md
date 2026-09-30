# Testing and CI

`cargo test` covers the formatting parser, SASL state machine (including every
failure path a hostile server can force), rate limiters, backoff bounds,
`ISUPPORT` parsing, channel/member state, and a set of **transcript tests** that
drive the real dispatch path with scripted server output.

`flutter test` covers the motion primitives: that they animate rather than snap,
that they stop when they are told to, and that they step aside entirely under
reduced motion. `make test` runs both suites, and neither needs a network or
Docker.

Live-network testing proved the TLS handshake, registration, `ISUPPORT` parsing,
error surfacing, and reconnect path against Libera.Chat. It is deliberately not
part of the test suite: it needs unfiltered egress and a cooperative server, so
it cannot be a regression asset.

The local server carries **24 of its own**, none of them ignored. Most drive
the protocol state directly; four start the real server and connect the real
client to it over real TLS, including a guard asserting that the same
connection is **refused** without the trust anchor — so if verification is ever
weakened, the suite says so instead of quietly proving nothing. These need
neither Docker nor a network, which means the client's own connection path is
now covered by an ordinary `cargo test` for the first time.

## A local server to test against

[`dev/README.md`](../dev/README.md) is the practical guide: what is on the server,
how to register an account for SASL, how to poke it by hand, and what it takes
to point the app itself at it.

```bash
make dev-server        # ergo on 127.0.0.1:6697, waits until the port accepts
make test-integration  # the end-to-end suite, against it
make dev-server-logs   # follow it
make dev-server-stop   # stop, keeping accounts and certificates
make dev-server-clean  # stop and throw the state away
```

This exists so the connection path can be exercised without unfiltered egress or
a public network's goodwill. It is a real server, not a mock: real TLS, real
registration, real `ISUPPORT`, and SASL with open account registration
(`REGISTER` works before connect), so the SASL path can be driven end to end.

**It serves TLS, not plaintext.** `ddirc-core` sets `use_tls: true`
unconditionally and never sets `dangerously_accept_invalid_certs`, so a
plaintext dev server would be unreachable and a "just disable verification for
tests" switch would put a certificate-skipping path into the shipped client.
Instead ergo generates a self-signed pair on first start, and anything
connecting trusts that certificate explicitly:

```
dev/ergo/fullchain.pem
```

The generated certificate already carries `localhost` and `127.0.0.1` in its
SAN, so hostname verification passes as-is.

`irc-core/ddirc-core/tests/dev_server.rs` drives it: connect over real TLS,
register, join, exchange a message between two clients, set a topic. Every test
is `#[ignore]`d, so `cargo test` stays hermetic for CI and for machines without
Docker. One of them is the guard — it asserts that **without**
`extra_root_cert` the same connection is refused, so if verification is ever
weakened the suite says so instead of quietly proving nothing.

Everything generated — config, certificates, the account datastore — lands in
`dev/ergo/`, which is gitignored. The config the entrypoint writes contains a
randomly generated oper password, so it is per-machine and never committed. The
listener is bound to loopback: this server has a self-signed certificate and
open registration, and must not be reachable from anywhere else.

## Continuous integration

`.github/workflows/lint.yml` runs `make lint` — `flutter analyze`, `cargo fmt
--check`, and `cargo clippy -D warnings` — on every push to `main` and every
pull request. It calls the Makefile target rather than repeating the commands,
so a local check and CI cannot drift apart.

Both toolchains are pinned. Clippy runs with `-D warnings`, and an unpinned
toolchain would fail CI on unchanged code the day a new lint ships.

`.github/workflows/test.yml` runs the suites, in two jobs. **hermetic** is
`make test` — the Dart widget tests and the Rust unit and transcript tests,
needing no network and no Docker. **integration** starts the dev server with
`make dev-server` and runs the end-to-end suite against it.

The integration job starts the server through the Compose file rather than a
`services:` block. The Compose file already describes the server, its
healthcheck and its loopback binding, and a service container would be a second
description to keep in step; it also puts the generated certificate in
`dev/ergo/` inside the workspace, which is where the tests look by default.

Lint and test are separate workflows so a formatting slip and a broken test
report as two different failures.

`.github/workflows/build.yml` answers a question neither of the two above can:
**does it still compile.** `make test` runs Dart on the Dart VM and Rust for
the host; `make lint` runs the analyzers. Between them they never invoke a
platform toolchain, so the Kotlin under `android/`, the C++ runner under
`windows/`, the Gradle build, the NDK cross-compile and the Inno Setup script
were all invisible to CI — a change to any of them could go green in both
workflows and first be built by a release tag, which is the worst moment to
find out. Two jobs, `make build-android` and `make installer`. It is the slow
one, because Rust cross-compiles once per Android ABI; the caches carry most of
that after the first run.

`.github/workflows/release.yml` publishes to a GitHub Release when a tag is
pushed: the **Android APK** and the **Windows installer**, one job each, both
uploading to the same release. It only ever fires on `v0.*` — not `v*` —
because that is what marks a release as beta in the tag itself: a `v1.0.0`
push is a claim this pipeline should not be able to make on its own, so
widening the pattern is left as a deliberate change for when that claim is
actually true.

Both release jobs start by running `.github/tag-matches-manifest.sh`, which
fails the release if the tag and `pubspec.yaml` disagree about the version.
There are three places a version lives and only two of them were checked:
`test/version_test.dart` keeps the manifest and `lib/src/version.dart` in step,
and nothing kept the tag in step with either — so a tag nobody bumped the
manifest for would ship an APK whose Android `versionName` came from the tag
and whose own settings screen came from the constant. Only `MAJOR.MINOR.PATCH`
has to match, because the tags here carry a suffix the manifest does not
(`v0.2.0+beta`), and that is a label on the release rather than a disagreement
about which version it is.

**The release APK is signed with the debug key** — that is what
`android/app/build.gradle.kts` names as the release signing config. Survivable
for a beta people sideload; not survivable for a store, or for any upgrade path
across a later key change. A real signing config is the thing to arrange before
this leaves beta.
