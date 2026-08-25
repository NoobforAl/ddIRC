# ddIRC

[![Lint](https://github.com/NoobforAl/ddIRC/actions/workflows/lint.yml/badge.svg)](https://github.com/NoobforAl/ddIRC/actions/workflows/lint.yml)
[![Test](https://github.com/NoobforAl/ddIRC/actions/workflows/test.yml/badge.svg)](https://github.com/NoobforAl/ddIRC/actions/workflows/test.yml)

A minimal, modern IRC client. Android-first, built on a reusable native core.

**Status:** Phases 1–4 complete.

- **Phase 1** — the Rust core connects, authenticates, and carries a
  conversation. 128 tests, clippy-clean, plus a live TLS connection to
  Libera.Chat that reached registration.
- **Phase 2** — the FFI boundary works end to end: `flutter_rust_bridge`
  generates the bindings, the core builds for both Android and Windows, and
  `libddirc_bridge.so` ships inside a built APK. Dart sees
  `connect() → Future<int>` and `eventStream() → Stream<IrcEvent>`.

- **Phases 3–4** — the real UI: saved network profiles with several
  connections live at once, channel list with unread and mention badges,
  member panel with `ISUPPORT` privilege prefixes, styled message view, and
  settings dialogs for the app, the current channel, and the server.

**Verified running as a Windows desktop app** against Snoonet: connected over
TLS, joined a channel, rendered the topic and member roster, sent messages and
a `/me` action, changed preferences live, and disconnected cleanly. Android
builds and installs, but has not yet been run on a device.

Phases 5–6 (security review, release prep) are still outlined rather than built.

## Networks

Each saved network is a **profile** — address, port, nickname, auto-join
channels, and an optional SASL account. Several can be connected at once; the
rail down the left side is the list of them.

```
┌──┬────────────┬─────────────────────────┬──────────┐
│SN│ #chat      │  conversation           │ members  │
│LC│ #dev       │                         │          │
│ +│ NickServ  2│                         │          │
└──┴────────────┴─────────────────────────┴──────────┘
 rail  channels          messages
```

A rail entry carries the network's initials, a status pip (green connected,
amber connecting, red failed) and an unread count that turns accent-coloured
when any of it is a mention. Click to switch, or to connect one that is down.
Right-click — long-press on touch — to edit it.

Everything is scoped per network: `#chat` on one server is a different
conversation, with its own notification level, from `#chat` on another.
Disconnecting one leaves the rest connected.

Profiles are stored in `shared_preferences`; **SASL passwords are not**. Those
go to the platform keychain via `flutter_secure_storage` — Android Keystore,
DPAPI on Windows — are read only at connect time, and are zeroized by the core
once authentication completes.

## Window

On desktop the app draws its own title bar: traffic-light close, minimise and
maximise on the left, their glyphs appearing on hover. The native caption is
hidden before the first frame, so it never flashes. Mobile is unaffected.

## The mark

A hash on a rounded square. `#` is the channel sigil — it is what an IRC
address looks like, it predates every other use of the character, and unlike a
wordmark it is still legible at sixteen pixels.

It is described once, as numbers, in `lib/src/ui/mark_spec.dart`: four strokes
and a corner radius, every value a fraction of the side. Two things read it.
`AppMark` paints it on the splash and the empty screen, and
`tool/make_icons.dart` rasterises it into every launcher icon — the Windows
`.ico` at seven sizes, Android's legacy and adaptive icons at five densities,
and a PNG and SVG under `assets/icon/` for anywhere outside a build.

```bash
make icons     # redraw them all; the output is committed
```

Each size is *drawn* at that size from signed distance fields rather than
downscaled from one master, which is why the 16px taskbar icon keeps its
counters. `flutter test` re-renders and compares bytes, so changing the spec
without rerunning the generator fails a test instead of shipping a stale icon.

## Settings

Three dialogs, reachable from the ⚙/⚌ controls in the header, and from a
right-click or long-press on any channel in the list.

| Dialog | What it holds |
|---|---|
| **App** | Timestamps, 12/24-hour clock, message density, whether joins and parts are shown, whether mIRC colours are rendered, the two logging switches, and the app-wide proxy. Applies to every server; persists. |
| **Channel** | Topic (editable), notification level — all / mentions only / muted, member counts, and leaving the channel. The level persists per channel. |
| **Server** | Nickname (changeable), and the connection as it actually is: status, host and port, network, transport, route (direct or through which proxy), authentication mechanism. Plus disconnect. |
| **Network** | The saved profile itself — name, address, port, channels, nickname, SASL account, whether to connect at launch, and this network's proxy. Reached from the rail's context menu or the header menu. |

Preferences live in `shared_preferences`. **No credential is ever written
there** — see [SECURITY.md](SECURITY.md).

Invalid input is reported on the field itself: the field turns red, states the
problem underneath, and shakes. Nothing is reported in a banner somewhere else
on the screen, and the layout never reflows.

## Proxy

Off. SOCKS5, and nothing else.

There are two settings and they meet in one place. The app has a proxy; each
network chooses what to do about it:

| Choice | Effect |
|---|---|
| **App default** | Follow the app-wide setting. What every network starts as, and what a profile saved before proxies existed reads back as. |
| **Direct** | Never proxy this network, whatever the app is set to. |
| **Custom** | This network's own proxy. |

Global-as-default with a per-network override, rather than a global proxy that
admits no exceptions. One setting covers "put everything through Tor", and the
override exists because a LAN server or a private bouncer is often reachable
only directly — a proxy with no exceptions makes one network's requirements
break every other network with no way to see why. `Direct` is a choice you make
out loud rather than something an empty field does by accident.

Three things are true of the connection either way:

- **The proxy carries it; it does not terminate it.** TLS is negotiated end to
  end with the IRC server *through* the tunnel and verified against the
  server's own name. A proxy operator sees ciphertext to a host they were told
  about, and nothing else.
- **The name is resolved at the far end.** SOCKS5 is given the hostname, not an
  address, so a proxy meant to hide where you are is not undone by a DNS lookup
  from here that announces it. That is why SOCKS5 rather than an HTTP proxy,
  and it is what Tor's local listener speaks.
- **There is no fallback.** A proxy that cannot be reached is a connection that
  fails. Quietly dialling direct instead would defeat the one thing a proxy is
  for, at exactly the moment it mattered most.

### Onion addresses

A `.onion` address works through the same setting, and needs no special mode:
SOCKS5 hands the name to Tor, which resolves it, and TLS is then negotiated and
**verified** against that name exactly as for any other host.

Nothing is relaxed for onion services, and that is deliberate. Tor proves
*which service* answered — the address is a public key — but it says nothing
about the connection running inside the tunnel, and skipping the certificate
check would mean trusting the proxy to be Tor when nothing here can know that
it is. An onion service reachable from ddIRC is one holding a certificate
issued for its own `.onion` name, which is permitted and is the only
arrangement that does not weaken the client.

Two conveniences follow from that: an onion address saved without a proxy is
refused at validation rather than failing later as a DNS error about a name
that is not in DNS, and a certificate failure on an onion address names the fix
specific to onions instead of the generic self-signed advice.

A username and password are optional and, if given, are stored in the platform
keychain beside the SASL one — never in app settings. Worth knowing before
typing one: SOCKS5 sends both to the proxy in the clear, before any TLS exists
(RFC 1929). They prove who you are to the proxy and protect nothing else. Tor
accepts any pair and uses it to put the connection on a circuit of its own.

`ddirc-cli --proxy 127.0.0.1:9050` exercises the same path without Flutter, and
`dev/` carries a fixture for each half of the setting — `make dev-proxy` for a
plain SOCKS5 proxy in front of the local server, offline and deterministic, and
`make dev-tor` for the real thing against a public network. See
[dev/README.md](dev/README.md).

## Logs

Off. Both of them, until someone turns them on.

| | Records | Where |
|---|---|---|
| **Chat log** | What was said, as plain text | `logs/chat.log` |
| **Debug log** | Connection and protocol events, never message content | `logs/debug.log` |

Two switches rather than one, because they carry very different risks. Someone
chasing a connection bug needs the second and has not thereby agreed to record
their conversations in the first.

Both live in `logs/` inside the application support directory — the app's own
private data folder, the same one holding the settings file:

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\dev.ddirc\ddirc\logs\` |
| Android | `/data/user/0/<package>/files/logs/` — app-private internal storage |
| Linux | `~/.local/share/ddirc/logs/` |
| macOS / iOS | `~/Library/Application Support/<bundle>/logs/` |

Deliberately not Documents, Downloads or external storage. On Android those are
readable by anything holding the storage permission, and a chat log is the last
file in this app that should be. The folder is shown in App settings *before*
either switch is turned on, and nothing is created on disk until there is a
line to write — a user who never enables logging never gets a stray folder.

Each file is capped at 5 MB with one rotated copy kept, so the pair has a
ceiling rather than growing until a disk fills. A redaction pass blanks
anything shaped like a credential on the way into the debug log; it is a
backstop rather than the defence, since the core strips secrets before they
ever become events. Write failures are swallowed — a full disk must not
interrupt a conversation over a diagnostic.

## Why Rust, not C

The original design called for a C core wrapping `libircclient`. That turned out
not to be viable:

- **The named dependency does not exist.** `github.com/vitalyster/libircclient`
  returns 404, and no equivalent fork is on GitHub. The only surviving sources
  are a 2018 SourceForge tarball (autotools, no git) and `shaoner/libircclient`,
  frozen at v1.6.0 from 2013.
- **Its TLS is hardcoded to OpenSSL**, and OpenSSL does not support
  cross-compiling to Android from a Windows host — its own `NOTES-ANDROID` says
  to use a Unix host.

Rust removes both problems at once. The `irc` crate's `tls-rust` feature uses
**rustls**, which cross-compiles to Android from Windows with nothing but the
NDK — verified, producing working `arm64-v8a` and `armeabi-v7a` libraries with
zero OpenSSL references. Safe Rust also eliminates by construction the entire
class of memory-safety requirements the original C plan had to enforce by
discipline.

(rustls is not literally 100% Rust: its default crypto provider `aws-lc-rs`
contains C and assembly. It needs no external toolchain beyond the NDK's own
clang, which is the property that actually mattered here — OpenSSL's Android
build wanted perl, make, and a Unix shell.)

Go was considered and rejected. [`girc`](https://github.com/lrstanley/girc) is
the best-maintained IRC library in any language right now, but the Go runtime
installs signal handlers that conflict with the Dart and ART VMs, cgo's pointer
rules constrain callbacks, and no Go↔Flutter bridge approaches
`flutter_rust_bridge`'s health.

## Layout

The repository root **is** the Flutter application; the native side lives
beside it in one Cargo workspace.

```
ddIRC/
├─ lib/               # Dart UI + generated bindings under lib/src/rust
├─ assets/icon/       # the mark as PNG and SVG, generated
├─ tool/              # build-time scripts: make_icons.dart
├─ android/           # Flutter Android host
├─ windows/           # Flutter Windows host
├─ rust_builder/      # cargokit glue that builds Rust during a Flutter build
├─ irc-core/          # the Cargo workspace
│  ├─ ddirc-core/     # the reusable core — no Flutter awareness
│  ├─ ddirc-cli/      # terminal harness; the Phase 1 acceptance gate
│  └─ ddirc-bridge/   # ddirc_bridge — the frb binding crate
└─ pubspec.yaml
```

`ddirc-core` knows nothing about Flutter or `flutter_rust_bridge`. The binding
crate `irc-core/ddirc-bridge` depends on it and owns every DTO that crosses into
Dart, which is what keeps the core reusable for desktop, CLI, and iOS
unchanged.

### Core modules

| Module | Responsibility |
|---|---|
| `api/` | The entire public surface. No `irc`-crate type escapes through it. |
| `conn/actor.rs` | Owns the connection; one tokio task, no shared mutable state. |
| `conn/sasl.rs` | IRCv3 capability negotiation and SASL PLAIN, as a pure state machine. |
| `conn/ratelimit.rs` | Token buckets for outgoing pacing and incoming flood protection. |
| `conn/reconnect.rs` | Exponential backoff with equal jitter. |
| `state/` | Channels, members, privileges; `ISUPPORT` and casemapping. |
| `media/` | Removing metadata from images before they are sent. No codec: each format is rewritten as a container, pixels copied across untouched. |
| `text/format.rs` | Parses mIRC formatting into styled spans and strips control codes. |

## Building

Requires Rust 1.82+. The Android targets are only needed for Phase 2.

```bash
cd irc-core
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo audit
```

### Running the CLI harness

Secrets are read from the environment, never from argv — command lines are
visible to other processes and land in shell history.

```bash
export DDIRC_SASL_PASSWORD='...'
cargo run -p ddirc-cli -- \
  --server irc.libera.chat --nick yournick \
  --sasl-account youraccount --channel '#test'
```

Once connected: `/join #channel`, `/part [reason]`, `/nick <new>`, `/me <action>`,
`/msg <target> <text>`, `/quit`. Anything else is sent to the current channel.

### Building the Android app

Flutter is not on `PATH` here; use `C:\Users\noobf\flutter` (3.44.2 stable).
`C:\src\flutter` exists but has never been initialised — ignore it.

One-time setup:

```bash
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
cargo install cargo-ndk flutter_rust_bridge_codegen cargo-expand
flutter pub get
```

`cargo-expand` and the Dart `freezed` package are both required by codegen — our
event type is an enum carrying data, which becomes a sealed class in Dart.

```bash
export ANDROID_NDK_HOME="$LOCALAPPDATA/Android/Sdk/ndk/27.0.12077973"
export PATH="$HOME/flutter/bin:$PATH"   # codegen shells out to `flutter`
flutter_rust_bridge_codegen generate    # after changing irc-core/ddirc-bridge/src/api/**
flutter build apk --debug
```

Cargokit compiles the Rust automatically as part of the Flutter build; there is
no separate `cargo ndk` step. Generated Dart under `lib/src/rust/` is committed
so CI does not need the codegen toolchain.

### Building the Windows app

Needs Visual Studio with the C++ desktop workload (2026 18.9.1 works here).

```bash
flutter build windows --debug     # → build/windows/x64/runner/Debug/ddirc.exe
flutter run -d windows
```

### Building for Linux, macOS and iOS

Scaffolded, configured, and **not yet built by anyone** — every one of them
needs a host we do not have. They are here so that the first person with a Mac
or a Linux box starts from a project that is already wired up rather than from
`flutter create`, and so that the things which are easy to get wrong are
already right. Expect to fix something; do not expect to start from scratch.

```bash
make build-linux    # on Linux:  needs GTK 3, ninja, clang, pkg-config
make build-macos    # on macOS:  needs Xcode
make build-ios      # on macOS:  builds unsigned, for a simulator or a device
```

The Rust side needs nothing new: `rust_builder` (the `ddirc_bridge` plugin)
already ships cargokit glue for all five platforms, so the core is compiled by
the Flutter build exactly as it is on Windows and Android. On macOS and iOS you
will want `rustup target add` for the architectures you are building for.

What was set beyond the template:

| | |
|---|---|
| **macOS** | `com.apple.security.network.client` in **both** entitlement files. This is the one that matters: under the App Sandbox an outgoing connection is refused without it, and it surfaces as a TLS error rather than as a permissions one, so it costs an afternoon to find |
| **iOS** | Display name, and icons with no alpha channel — an iOS icon with one is rejected on upload |
| **Linux** | No `GtkHeaderBar`. The app draws its own title strip on every desktop, and a header bar is a *client-side* titlebar that survives undecorating on some window managers, leaving two of them. Default window size matches what `prepareWindow` asks for |
| all three | The mark, generated into each platform's icon format by `make icons` |

Bundle identifier is `dev.ddirc.ddirc` throughout, matching Android. There is no
signing configuration and no CI job for these — CI has no macOS runner, and a
Linux job would be the only one of the three it could ever run.

### Picking a network to test against

Libera.Chat is the default, but it rejects connections from many VPN exit IPs
via DroneBL — you get a clear "banned from this server" line and a backoff
retry, which is the client behaving correctly, not a bug. If that happens,
`irc.snoonet.org` accepts a wider range of addresses.

Avoid the bare `irc.dal.net` round-robin: some of its servers run **plaintext**
on 6697, so the TLS handshake fails with a frame error. Use a specific host such
as `twisted.dal.net` instead.

## Design notes

**We drive registration ourselves.** The `irc` crate's `identify()` sends
`CAP END` *before* `NICK`/`USER`, which closes capability negotiation before SASL
could run. The actor therefore sends the registration burst itself and lets
`conn/sasl.rs` decide when negotiation ends.

**SASL is ours.** The crate has no SASL support at all — only a `nick_password`
field for NickServ. We implement SASL PLAIN over its `CAP`/`AUTHENTICATE`
commands, exactly as [Halloy](https://github.com/squidowl/halloy) does. NickServ
remains the fallback when a server does not offer SASL or refuses it, and the UI
is told which happened, because the fallback is genuinely weaker: it
authenticates *after* connecting, so you are briefly present unauthenticated.

**We re-align MODE parameters.** The crate's `takes_arg` table is hardcoded and
claims `-l` carries a parameter, which it does not. On `MODE #c -l+o bob` that
shifts every later argument and grants ops to the wrong member. We keep only the
*order* of modes and arguments — which the crate does preserve — and re-align
them against the server's advertised `CHANMODES`.

**Casemapping is respected.** IRC nicks are case-insensitive, and under RFC 1459
`[]\` are the uppercase forms of `{}|`. Comparing with plain ASCII lowercase
would treat `Foo[bar]` and `foo{bar}` as two different users on a network that
considers them one.

**Motion is a token, not a per-widget decision.** `lib/src/ui/motion.dart` holds
three durations and two curves, read as `context.motion` — the same shape as the
colour tokens, for the same reason. The getter returns zero durations when the
platform's *reduce motion* setting is on, so honouring that is automatic instead
of something every call site has to remember. Nothing animates for decoration:
each transition answers *what just changed, and where did it go*. The one
looping animation is the status dot while a connection is pending, because amber
alone cannot tell "still trying" from "settled".

**Size is a token too.** `lib/src/ui/layout.dart` names three widths —
`compact`, `medium`, `expanded` — measured once at the top of the tree and read
as `context.layout`. Widgets ask it questions (`layout.channelsPinned`,
`layout.gutter`) rather than comparing pixel widths, because a breakpoint
buried in a widget is one nobody else can find, and the panes only read as one
app if they all change their mind at the same width. Three rather than two
because there are two independent decisions: the channel list earns its place
early, the member list only once the conversation between them is still wide
enough to read. Below `compact` the rail and the channel list share one
drawer — they answer the same question, so on a phone they are one button.

**The splash is shy.** Startup draws nothing for the first 140ms, so a warm
start never flashes a logo; if it does appear it stays long enough to be read.
It exists mostly for the case that used to produce an empty window and no
explanation: a native core that will not load now gets a sentence, the
underlying error, and a retry.

**A failure should say which hop broke.** A proxy doubles the number of
machines that can refuse a connection, and both refusals arrive as the words
"connection refused". They are fixed in completely different places, so
`conn/diagnose.rs` is told whether a proxy was in use and answers accordingly:
an unreachable proxy says nothing was sent to the server at all, a refusal
relayed through SOCKS5 names both the proxy and the destination, and something
on the port that is not SOCKS5 says so outright — pointing this at an HTTP
proxy is the commonest way to get there, and "Invalid response version" gives
no hint of it. The same instinct removes advice as well as adding it: "check
the address for a typo" is wrong under a proxy, because the name was never
ours to resolve.

**An error should name the thing that fixes it.** The `irc` crate's `Display`
for its most common error is, in full, `an io error occurred` — with the real
`io::Error` attached as a `#[source]` it never prints. So a mistyped hostname,
a firewall, a wrong port and a server that is simply down all reached the user
looking identical, and none of them suggested what to do. `conn/diagnose.rs`
classifies the error instead of printing it, names the host and port that
failed, and says what usually fixes that case; where it cannot classify one it
walks the source chain, which at minimum recovers the detail the crate dropped.
The same instinct applies at the other boundary: `AnyhowException.toString()`
is `AnyhowException(msg)`, with parentheses rather than a colon, so the tidy-up
that was meant to strip the wrapper silently matched nothing and users saw it.
It is unwrapped by type now, not by regex over a `toString`.

**A new message moves pixels, never layout.** `Arrive` fades and lifts a row
into place with a `Transform`, which costs no layout at all. That is not a
performance choice. The scrollback jumps to `maxScrollExtent` whenever a
message lands and you are already at the bottom, so an entry animation that
grew the row would move that target while the jump was being computed and
strand the newest line half off the screen. Two conditions have to agree
before a row animates — it has to be past the end of what was on screen last
build, *and* it has to have happened in the last second. The index alone
replays the tail every time you scroll back to it; the timestamp alone makes a
channel you join mid-conversation flash its whole backlog at once.

## Dependency posture

The `irc` crate (577★, 407k downloads) is the de-facto standard for Rust, but
upstream moves slowly — 36 open issues and an 8-month gap at the time of writing.
Both serious downstream users, [Halloy](https://github.com/squidowl/halloy) and
`repartee`, vendor their own in-tree fork.

We depend on the published crate and treat vendoring as a **planned escape
hatch**, not a surprise. IRC is a frozen protocol, so a fork carries no ongoing
maintenance tax. If we hit the gaps they hit — flood protection, rustls
behaviour — the fork goes in `irc-core/vendor/irc` and nothing else changes.

The proxy support is the crate's own `proxy` feature, backed by
`tokio-socks`. We take `tokio-socks` as a direct dependency as well, because
`conn/diagnose.rs` matches on its error variants and the `irc` crate does not
re-export the type — matching on Display strings instead would be one upstream
rewording away from silently losing every proxy diagnosis.

`Cargo.lock` is committed and `cargo audit` runs over the whole tree. See
[SECURITY.md](SECURITY.md).

## Testing

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

### A local server to test against

[`dev/README.md`](dev/README.md) is the practical guide: what is on the server,
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

### Continuous integration

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
