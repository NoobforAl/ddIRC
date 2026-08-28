# TODO

Only what is **not** done. Anything finished has been deleted from this file —
the reasoning behind a shipped decision lives in the source that carries it out,
and `git log` has the rest.

Ordered by size, smallest first, except where one thing blocks another.

## 1. Sending a file from behind a proxy

Everything else about DCC is built: offers are parsed, accepted and served, and
a transfer through a proxy is dialled through it. The one gap is *sending* while
a proxy is configured, which is currently **refused** with a reason rather than
falling back to a direct offer — a fallback would publish the address the proxy
exists to hide, which is the thing the whole rule in `dcc/transfer.rs` prevents.

What it needs is a reverse offer of our own: send `DCC SEND <file> 0 0 <size>
<token>`, wait for the receiver's reply naming *their* address and echoing the
token, then dial them through the proxy and serve. `serve_by_dialling` already
exists and has a test that moves real bytes; nothing calls it yet. What is
missing is the token round-trip, which means keeping a map of outstanding tokens
on the actor and matching an incoming offer against it.

One thing to fix on the way: `offer::parse_send` discards the token on a normal
offer, because today only a reverse one carries a meaningful one. The reply to a
reverse offer is a normal offer *with* a token, so that field has to survive and
`is_reverse` has to become `port.is_none()` rather than `token.is_some()`.

## 2. Signing the Windows installer

`make installer` produces an unsigned `.exe`, so SmartScreen warns the first
person to run each release until enough people have run it anyway. The installer
itself is done; this is the part that was deliberately left as a decision rather
than guessed at, because it costs money and ties releases to a certificate that
has to be kept somewhere.

Open: whether to buy a code-signing certificate at all, and if so where the key
lives so that a release can be built without it sitting in the repository.

## 3. Build the Android app, then run it on a phone

**The Kotlin added for message notifications has never been compiled.**
`MessageNotifications.kt` and the two new methods on `MainActivity` were written
against a toolchain that could not be reached — Gradle could not resolve the
Kotlin plugin at all — so the first person with a working Maven mirror should
expect to fix something small before anything else here is worth trying. The
Dart half of the same feature is built and tested.

After that, the part no test can reach. Android has never been started on a real
device, and three things depend on that changing:

- The **foreground service** — whether it survives the app going to the
  background for an afternoon, and what Android does to it overnight.
- The **message notifications** — whether they arrive while the app is not in
  front, whether tapping one lands in the right conversation from both a cold
  start and a warm one, and whether the two notification channels appear
  separately in system settings.
- **File transfers**, which have only ever run over loopback on one machine.
  A phone behind carrier NAT will usually not be reachable for a direct offer at
  all, which is the same problem item 1 solves and the reason it matters more on
  mobile than on a desktop.

## 4. Prove the other three platforms

macOS and Linux are scaffolded, configured and built by nobody. Notifications
and the file picker both nominally work there — `local_notifier` and
`file_selector` cover them — and those claims have exactly as much evidence
behind them as the builds do, which is none.

iOS stays deliberately out of scope.
