# ddIRC

[![Lint](https://github.com/NoobforAl/ddIRC/actions/workflows/lint.yml/badge.svg)](https://github.com/NoobforAl/ddIRC/actions/workflows/lint.yml)
[![Test](https://github.com/NoobforAl/ddIRC/actions/workflows/test.yml/badge.svg)](https://github.com/NoobforAl/ddIRC/actions/workflows/test.yml)

A minimal, modern IRC client. Android-first, built on a reusable native core.

> [!WARNING]
> **This is beta software.** It connects and it works, but it has not been
> through a security review, it has not been run by many people, and the Android
> build has never been started on a real device. Read
> [the local server](docs/local-server.md) before turning it on, and treat this the way you would treat any client
> you had just compiled yourself.

**How this was written.** I built ddIRC for myself. Some of the Rust core is
mine, written by hand; most of the rest — the whole Flutter UI, and much of the
code around the core — is vibe-coded with an AI assistant. It is tested and it
is linted, and the reasoning behind each decision is in the commit that made it,
but that is what it is. Weigh it accordingly before trusting the client with
anything that matters.

## What it does

- **Several networks at once**, each a saved profile with its own channels,
  nickname and optional SASL account. A curated list of live networks to start
  from, and `.irc` files or QR codes to move a network between devices.
- **Private by default.** A fresh install routes everything through the
  bundled Tor. TLS on every connection, no CTCP replies, no fallback to a direct
  connection. Logs and message history are off until you turn them on.
- **Direct messages need your consent.** A first message from a stranger is a
  request; declining blocks them on that network.
- **Stays connected in the background**: a tray icon on desktop, a foreground
  service on Android, with notifications for DMs and mentions only.
- **DCC file transfers**, with image metadata stripped before sending.
- **An MCP server** (beta, off) so an AI agent can read conversations and draft
  replies. Nothing is sent without your approval.

**Not yet:** the Windows installer is unsigned, so SmartScreen warns on first
run. Sending a file through a proxy is refused. macOS and Linux are configured
but have never been built.

## Install

Download the Android APK or the Windows installer from
[Releases](https://github.com/NoobforAl/ddIRC/releases). The Windows installer
is per-user and never asks for administrator rights. To build from source, see
[docs/building.md](docs/building.md).

## Documentation

| Document | Covers |
|---|---|
| [Building and installing](docs/building.md) | Toolchains, the CLI harness, Android, Windows and the installer, Linux/macOS/iOS |
| [Features](docs/features.md) | Networks, DMs, browsing, `.irc` import/export, the window and background running, notifications, settings, file transfers, agents (MCP) |
| [Privacy](docs/privacy.md) | What is sent about you, the proxy and Tor, onion addresses, logs, message history |
| [The local server](docs/local-server.md) | The loopback-only IRC server inside the app |
| [Architecture and design](docs/architecture.md) | Repository layout, core modules, why Rust, design notes, dependency choices, the icon |
| [Testing and CI](docs/testing.md) | Test suites, the dev server, CI and release workflows |
| [The `.irc` file format](docs/irc-file-format.md) | Writing a network config by hand |
| [SECURITY.md](SECURITY.md) | The security posture: transport, secrets, untrusted input, outgoing data |
| [dev/README.md](dev/README.md) | Running a local IRC server, proxy or Tor to develop against |

Quick check that everything builds and passes:

```bash
make test    # Rust and Dart suites, no network or Docker needed
make lint
```

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md). The short version: AI assistance is used
here and is welcome, unread output is not; run `make test` and `make fix` before
opening anything; and put the reasoning for a change in the commit message,
because that is where this project keeps it.

## Licence

**GPL-3.0-or-later.** The full text is in `LICENSE`.

Everything bundled is compatible with it: arti and its tree are
`MIT OR Apache-2.0` throughout, and the rest of the workspace was already
permissive. The obligation runs the other way, which is the point of choosing
it — a client whose job is to be checkable should be checkable by whoever ends
up holding it.

**One consequence, decided rather than discovered:** app stores are off the
table while the licence stands. Store terms have historically conflicted with
the GPL's redistribution rights — a store grants its own, narrower licence to
whoever downloads a build, which is not a thing the GPL lets a distributor do —
and Google Play is the store this would matter for, since iOS is deliberately
out of scope. So Android is distributed as an APK, from releases, and the
licence is what is being kept. If that ever needs to change it is a relicensing
decision with contributors to ask, not a packaging detail.
