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

`core/ddirc-core/tests/dev_server.rs` drives it: connect over real TLS,
register, join, exchange a message between two clients, set a topic, ask WHOIS
about someone online and someone not, and carry IRC formatting — what markdown
in the composer becomes — from one client to another intact. Every test
is `#[ignore]`d, so `cargo test` stays hermetic for CI and for machines without
Docker. One of them is the guard — it asserts that **without**
`extra_root_cert` the same connection is refused, so if verification is ever
weakened the suite says so instead of quietly proving nothing.

Everything generated — config, certificates, the account datastore — lands in
`dev/ergo/`, which is gitignored. The config the entrypoint writes contains a
randomly generated oper password, so it is per-machine and never committed. The
listener is bound to loopback: this server has a self-signed certificate and
open registration, and must not be reachable from anywhere else.

## A local XMPP server to test against

```bash
make dev-xmpp               # ejabberd on 127.0.0.1:5223; alice and bob, password hunter2
make test-integration-xmpp  # the end-to-end suite, against it
make dev-xmpp-stop
```

The same idea as the IRC server above, for the other protocol. It is ejabberd in
its stock configuration with only a self-signed certificate mounted, listening
for TLS from the first byte on loopback and nowhere else. The tests trust
`dev/xmpp/certs/localhost.crt` directly, so certificate verification runs
exactly as in release.

These tests exist because the scripted-server test (`xmpp_round_trip`, which
needs nothing installed and runs in `make test`) can only prove the code does
what its author expected. They talk to software that does not share those
assumptions, and the two worst bugs this protocol had - a login storm after a
server restart, and a private reply that would have been heard by a whole room -
were found by them and by review respectively, not by anything scripted.
`recovers_and_rejoins_when_the_server_restarts` restarts the container under a
live session, so it needs the `docker` command as well as the server;
`DDIRC_XMPP_LOG=1` prints the library's own log for it.

The server also publishes `5443` on loopback, which is where the upload slot it
hands out points; `a_file_is_uploaded_and_the_link_reaches_the_other_person`
uploads 300 kB through it and fetches the link back to check the bytes are the
ones that were sent. Contacts, corrections and chat catch-up have tests of the
same kind. One of them is deliberately strict: it delivers a message to an
earlier session, so ejabberd cannot hold it as an offline message, and then asks
a fresh session for it by time - the only way to get it is the archive. These
tests share two accounts, so they leave the contact list empty when they finish
and clear it when they start.

## Memory and speed

Two things are measured, because both were once guessed at and wrong.

**The Rust session** has a counting allocator and a stopwatch around it:

```bash
cargo test -p ddirc-core --test xmpp_perf --release -- --ignored --nocapture --test-threads=1
```

It feeds the XMPP session a busy room (100,000 messages), a thousand-message
stream of private chats, a 2,000-contact roster with 200,000 presence changes
and 20,000 corrections, and prints time per stanza, allocations per stanza, the
memory still held afterwards and the high-water mark. Two assertions make it
more than a stopwatch: **memory held after 100,000 messages must not be more
than after 20,000** (the session holds a bounded amount of anything the network
can make it hold, and this is the test that says so at scale rather than with
three messages), and **a stanza must cost under 200 microseconds**, a ceiling
that exists so an accidental linear scan fails loudly. One did: the message
index and the room's recent-id window were walked in full for every message,
which was 2,000 and 512 string comparisons to record one, and a room message
cost 56 microseconds for it. Both are hashed now (10.5 microseconds), and a
randomised test runs the new index against the old behaviour through twelve
thousand mixed operations, holes and evictions included.

**The app** is measured on a real phone against a real server. The flood
generator puts a crowd in a room - sixty accounts each saying something every
two seconds, a tenth of it addressed to you:

```bash
DDIRC_FLOOD_ROOM=room@conference.localhost DDIRC_FLOOD_SECS=90   cargo test -p ddirc-core --test dev_xmpp --release -- --ignored --nocapture flood
```

and `adb shell dumpsys meminfo <package>` before and after, `top` beside it, and
`adb shell dumpsys gfxinfo <package>` for dropped frames. Use a **release**
build: a debug one carries its own interpreter and asserts, and its numbers are
about itself.

The layout tests (`test/xmpp_layout_test.dart`) render the XMPP dialogs on a
320x568 phone, at text twice the normal size, right to left, with names ninety
characters long and three hundred contacts, and fail on any overflow stripe or
exception. They found a real one: the buttons on a contact request were wider
than the screen when text was turned up.

## Continuous integration

One workflow starts everything, and it decides the order:

```
changes ──┬── lint ──┐
          └── test ──┴── build ── ci
```

`.github/workflows/ci.yml` runs on every pull request and every push to `main`.
`lint.yml`, `test.yml` and `build.yml` are workflows of their own - so each can
be read and run by hand, and `release.yml` reuses them - but none of them starts
on an event; they are called from here.

**A build is never started for a change that does not pass lint and the
tests.** Build is the slow workflow (Rust cross-compiled, a Windows installer, a
Linux one), and a formatting slip or a failing test would otherwise pay for all
of it before anyone read the first red mark. Lint and test run side by side, so
the wait is the longer of the two, not the sum.

**A change that touches only documentation runs nothing.** The `changes` job
reads which files changed (from the API, nothing is fetched); if every one is
Markdown, `docs/`, the licence, the issue forms or Dependabot's configuration,
the three workflows are skipped, and a skipped job counts as passing for a
required check. The workflow-level `paths-ignore` is deliberately not used for
this: it would leave a required check waiting for ever on a change it skipped.

**`ci` is the one check to require.** It succeeds when everything that ran
succeeded, and fails when anything failed or was cancelled, so branch protection
can ask for it alone instead of a list of jobs that changes whenever one is
added.

A new push to a pull request cancels the run already in flight; on `main` every
push is kept, so a merge is never hidden behind the next one.

### Lint

`lint.yml` runs `make lint` - `flutter analyze`, `cargo fmt --check` and
`cargo clippy -D warnings`. It calls the Makefile target rather than repeating
the commands, so a local check and CI cannot drift apart. Both toolchains are
pinned: clippy runs with `-D warnings`, and an unpinned toolchain would fail CI
on unchanged code the day a new lint ships.

### Test

`test.yml` runs the suites. **hermetic** is `make test` - the Dart widget tests
and the Rust unit and transcript tests, needing no network and no Docker.
**integration** starts the dev server with `make dev-server` and runs the
end-to-end suite against it. **integration-xmpp** does the same for XMPP,
with `make dev-xmpp` and `make test-integration-xmpp`.

The integration job starts the server through the Compose file rather than a
`services:` block. The Compose file already describes the server, its
healthcheck and its loopback binding, and a service container would be a second
description to keep in step; it also puts the generated certificate in
`dev/ergo/` inside the workspace, which is where the tests look by default.

Rust test binaries are built with line tables and no more debug information
(`CARGO_PROFILE_DEV_DEBUG`): it is most of what the linker writes, nothing here
reads a debugger's output, and a backtrace still names the line.

### Build

`build.yml` answers a question neither of the two above can: **does it still
compile, and does it still install.** `make test` runs Dart on the Dart VM and
Rust for the host; `make lint` runs the analyzers. Between them they never
invoke a platform toolchain, so the Kotlin under `android/`, the C++ runner
under `windows/`, the Gradle build, the NDK cross-compile, the Inno Setup script
and the Linux installer were all invisible to CI - a change to any of them could
go green and first be built by a release tag, which is the worst moment to find
out. Three jobs:

- **android** - `make build-android`, narrowed to one ABI (`ANDROID_TARGET`):
  this asks whether it compiles, and the Rust cross-compile, once per ABI, is
  most of the time it takes. The release builds all three. The Gradle
  distribution and dependencies are cached.
- **windows** - `make installer`: the release build and the Inno Setup script.
- **linux** - `make installer-linux`, then a check that nothing the program
  links against is missing, then `make test-installer-linux` against the real
  file: installed, upgraded and uninstalled in a throwaway home. That script
  (`linux/installer/smoke-test.sh`) is the only test the installer has, and the
  one thing nothing else covers.

Both installers are kept for a week as workflow artifacts, so a pull request's
can be tried without building it.

### Speed

The slow part is Rust and Gradle, so that is what is cached and what is not
repeated. `ci.yml` stops a build that was never going to be wanted (above); the
Rust cache is saved from `main` and from release tags only, and a pull request
restores it and adds nothing, so PRs cannot evict the cache the next build on
`main` needs; the toolchain pins and their cache live in one composite action
(`.github/actions/setup`) rather than nine copies; the Linux system packages in
another (`.github/actions/linux-deps`), where a test job installs only what
`flutter test` needs; and the compile-check Android build is one ABI, not three.
Dependabot watches the composite actions as well as the workflows.

### Release

`release.yml` runs when a tag is pushed, and publishes the **Android APK**, the
**Windows installer** and the **Linux installer**, with a `SHA256SUMS` file.

```
verify ── lint ──┬── android ──┐
      └─ test ───┼── windows ──┼── publish
                 └── linux ────┘
```

**Nothing is built for a tag that does not pass.** The tag has to agree with the
manifest, and lint and the full test suite have to pass, before the first
installer is compiled.

**Nothing is published unless everything was built.** Each platform builds and
uploads an artifact; only `publish`, which needs all three, makes the release.
Each job used to publish its own asset, so one failing left a release with an
APK and no installer - a release that looks complete and is not. Now a failed
build means no release at all, and the answer is the next tag. A tag pushed
while an older one is building cancels it, and that can no longer leave a
half-made release behind.

It only ever fires on `v0.*` - not `v*` - because that is what marks a release
as beta in the tag itself: a `v1.0.0` push is a claim this pipeline should not
be able to make on its own, so widening the pattern is left as a deliberate
change for when that claim is actually true.

The first job runs `.github/tag-matches-manifest.sh`, which fails the release if
the tag and `pubspec.yaml` disagree about the version. There are three places a
version lives and only two of them were checked: `test/version_test.dart` keeps
the manifest and `lib/src/version.dart` in step, and nothing kept the tag in
step with either - so a tag nobody bumped the manifest for would ship an APK
whose Android `versionName` came from the tag and whose own settings screen came
from the constant. Only `MAJOR.MINOR.PATCH` has to match, because the tags here
carry a suffix the manifest does not (`v0.2.0+beta`), and that is a label on the
release rather than a disagreement about which version it is.

**The release APK is signed with the debug key** - that is what
`android/app/build.gradle.kts` names as the release signing config. Survivable
for a beta people sideload; not survivable for a store, or for any upgrade path
across a later key change. A real signing config is the thing to arrange before
this leaves beta.

### Issue forms

`.github/ISSUE_TEMPLATE/` has a bug report and a feature request, and points
security reports at GitHub's private advisory form instead of a public issue.
Blank issues stay enabled: CONTRIBUTING asks for a change to arrive explained,
not for a form to be filled in.
