# TODO

Ordered easiest first. Everything left carries either a new dependency, a
per-platform decision, or an unanswered question.

Both of those opening questions have now been answered — see items 1 and 2 —
so what is left is code, plus one judgement call about a large dependency.

Everything here ships **disabled by default**. Items marked **beta** should
additionally be labelled as such in the UI.

## 1. Built-in Tor — beta

- **Ship Tor rather than expect it.** ✅ **The research is done**; the decision
  to adopt is deliberately not made. The numbers below are measured rather than
  estimated.

  Half of this already works, and is tested. Anyone running Tor themselves can
  point the proxy setting at `127.0.0.1:9050` today — the form starts on that
  port for exactly that reason — and `make dev-tor` brings up a real Tor for
  exercising it. What is left is bundling it, so that using Tor does not first
  require installing Tor.

### What the research found

Measured against `arti-client` **0.45.0**, built for `x86_64-pc-windows-msvc`
with `opt-level = "z"`, LTO, `panic = "abort"` and stripping — the most
favourable settings available, not a debug build.

| | |
|---|---|
| **Binary size** | **+3.83 MB** against an identical binary carrying only tokio (0.21 MB to 4.04 MB) |
| **Dependency tree** | **507 crates**, 36 of them `tor-*` |
| **MSRV** | **1.91** — this workspace pins **1.82**, so adopting it moves that |
| **Licence** | `MIT OR Apache-2.0` throughout, with nothing copyleft anywhere in the tree. The obligation is attribution, which the app stores are content with |
| **Bootstrap time** | **Not established.** See below |

Three integration costs that only appeared by building it, and would otherwise
have been found the hard way:

- **It does not link out of the box.** `arti-client` pulls `rusqlite` for its
  directory cache, which by default expects a system `sqlite3` — on Windows
  that surfaces as `LNK1181: cannot open input file 'sqlite3.lib'`. The answer
  is the `static-sqlite` feature, which compiles SQLite from source and so
  wants a C toolchain on *every* target, the Android and iOS ABIs included.
- **It collides with our TLS.** Arti's `rustls` feature selects the `ring`
  crypto provider; this tree is on `aws-lc-rs`, because `irc` takes
  `tokio-rustls` with its defaults. Cargo unifies features, so enabling arti's
  would turn *both* on, and rustls 0.23 answers "both" with a panic at the
  first handshake rather than an error at build time — the client would stop
  connecting to anything at all. One line fixes it, by installing a process
  default provider at startup, but it has to be known about first.
- **`zstd-sys` and `ring` bring their own C and assembly**, which is the same
  cross-compilation surface a second time.

### The question still open

**Whether embedded Arti actually works is unanswered**, and this machine could
not settle it. It reaches the Tor network — two completed channel handshakes
with real relays, and a circuit built — and then never obtained a consensus, in
runs of 5 and 25 minutes. Raw TCP to three of the four directory authorities
succeeds from here, so a restricted egress path is the likelier explanation
than an Arti fault, but that is not proof either way.

**Nothing should adopt a 507-crate dependency on the strength of a bootstrap
that has never been seen to finish.** The next step is one timed run on an
unrestricted network. If it bootstraps in tens of seconds the case is strong;
if it takes minutes, a client that reconnects at launch has a problem worth
designing around, and the external proxy that already works looks better.

### If it is adopted

The seam already exists, which is why none of this is urgent. `resolveProxy` in
`lib/src/model/proxy.dart` decides exactly one thing — which `ProxyConfig` a
profile connects through. Built-in Tor is a fourth arm on that switch,
resolving to whatever loopback port the embedded SOCKS listener bound. Nothing
underneath it has to change.

## 2. A local IRC server — beta

- **Run an IRC server inside the app.** ✅ **The scope question is settled and
  the server is built**, in `irc-core/ddirc-server/`. ⛔ **Not reachable from
  the app yet** — it has no FFI and no settings switch. See *What is left*.

### The scope question, answered: loopback only

Not a first step but a decision, for a reason that outlives the first version.

Reaching this server from *another machine* means that machine's client has to
be handed a trust anchor, because the certificate is issued locally and no
public authority will ever vouch for it. Handing someone a certificate to
install is precisely the control this codebase has refused to build:
`extra_root_cert` is deliberately absent from the FFI type so that nothing a
user can be talked into typing becomes a trusted root. A local server is not a
good enough reason to open that door, and opening it for this would open it for
everything after it.

The duller half of the answer is just as real. A server other people can reach
needs a routable address, a way through NAT, and a port nobody else has taken.
An app cannot arrange any of those, and pretending otherwise ships a feature
that works on the developer's machine.

**There is a real answer for "reachable from elsewhere", and it is not a bigger
listener**: publish it as an onion service, where the address is the key, NAT
stops mattering, and Tor authenticates which service answered. That depends on
item 1 — and `arti-client` carries an `onion-service-service` feature for
exactly this. So the order the two want doing in is Tor first, this second.

### The TLS story, answered: it issues its own, and that is not a bypass

The client sets `use_tls` unconditionally and has no bypass, so a plaintext
local server would be unreachable from the app it lives inside. It therefore
speaks real TLS, which the client really verifies.

What makes generating a certificate safe here, when trusting a supplied one
would not be, is that **the app is both ends of the connection**: it issues the
certificate and is the only thing that will ever be shown it. No certificate
from outside the machine enters the trust store, the anchor is scoped to one
loopback address the app itself chose, and the private key never leaves the
machine.

The shape is a **persisted CA and an ephemeral leaf**. The CA is written to the
app's own private data directory, because the client's trust anchor has to
survive a restart; the leaf is minted in memory at every start and written
nowhere, so the key that actually terminates connections lives exactly as long
as the server does.

### What was built

- Loopback only — `127.0.0.1` and `::1`, on the same port, so `localhost` works
  whichever way it resolves. An ephemeral port by default, since nothing needs
  the number in advance and a fixed one is a port something else may already be
  holding.
- Registration with `CAP` negotiation, `ISUPPORT`, a MOTD, `JOIN`/`PART`,
  `PRIVMSG`/`NOTICE`, `NAMES`, `TOPIC`, nick changes, `PING`/`PONG` and `QUIT`.
- One owner and no locks: a reader and a writer task per connection, and a
  single task holding all the state. A server is almost entirely cross-client
  operations — a join touches everyone in the channel, a rename everyone who
  shares one — and doing that under per-client locks is how deadlocks and
  half-applied state get in.
- **The MOTD says it is beta**, because a MOTD is the one thing every client
  shows on arrival, and whoever connected may not be whoever started it.

**Two new crates, both pulled in by `rcgen`** — `yasna` and `time`. Everything
else was already here: `irc-proto` is what the client itself is built on, so
the server parses and writes exactly what the client does rather than carrying
a second implementation to keep in step, and `rustls` and `tokio-rustls` arrive
with the `irc` crate's `tls-rust`.

`rcgen` is the one judgement call. X.509 could have been hand-rolled the way
`media/` hand-rolls its containers, but the calculus is different: a container
that is subtly wrong shows up as a file that will not open, whereas a
certificate that is subtly wrong is fed to a verifier that has to accept it
*and* has to keep refusing what it should refuse.

**24 tests, none of them ignored.** The protocol ones drive the state directly
with no socket in sight; four more start the real server and connect the real
client to it over real TLS — including the guard that the same connection is
*refused* without the anchor, so that if verification is ever weakened the
suite says so instead of quietly proving nothing. Unlike `dev_server.rs` these
need neither Docker nor a network, which means the client's own connection path
is now exercised by an ordinary `cargo test`.

### What is left

1. **The FFI.** `ddirc-bridge` has to start and stop it, and hand back the port
   and the anchor path. `extra_root_cert` stays off the Dart-visible type: the
   bridge fills it in for this one profile, the way `dev_root_cert()` already
   does for the dev server in debug builds.
2. **The settings switch, carrying a beta label**, and a profile pointed at the
   server so it can be reached without anyone typing an address.
3. A `BetaBadge` in the settings vocabulary, since item 1 will want the same one
   and two of them would drift.

## 3. Sending media — beta

**Blocked on a decision** — see *The problem to solve* at the end of this
section. The specification below is worth keeping either way; what is
undecided is what carries the bytes.

A protocol for sending files over IRC, since there is no standard one for
in-band transfer.

### Defaults

1. ✅ **Strip metadata before sending** — built, in `media/`. See *Done*. It
   was separable because it does not depend on how the bytes travel; the rest
   of this section does.
2. **Send in chunks, base64 encoded**, with a handshake first and an
   acknowledgement per chunk.

### Handshake

The sender opens with the file's description and hash. Use a fast hash rather
than a cryptographic one — BLAKE3 or xxHash — since this detects corruption
rather than tampering.

```
Filename: xxx, size: <bytes>, hash: xxx, chunk_size: <bytes>,
total_chunks: xxx, encoding: base64
```

Fields worth adding to the ones above:

| Field | Why |
|---|---|
| `transfer_id` | Two transfers between the same pair of users otherwise cannot be told apart, and every later message has to name the one it belongs to. |
| `version` | The first version of a protocol that cannot say which version it is can never be changed compatibly. |
| `mime_type` | So the receiver can refuse a type it will not display, before spending the transfer on it. |
| `hash_algorithm` | Names the algorithm rather than assuming it, so it can be changed later. |
| `encoded_size` | Lets the receiver check the total it was given against the total it got, independently of the chunk count. |

*Open question:* the original note said `expected file: xxx`, whose meaning is
not clear — it may be the filename after decoding, or the expected type.
Worth settling.

*Open question:* `encoding: base64 or 128`. Base64 is the safe choice on IRC,
which is byte-oriented but full of characters that carry protocol meaning.
There is no standard "base128"; if the goal is a denser encoding, Ascii85 is
the usual candidate, at roughly 25% overhead against base64's 33%. It is
worth confirming whether that gain justifies the risk of encountering a
character some server mangles.

### Transfer

- Each chunk is sent as `part <n>: <payload>, hash: xxx`.
- The receiver acknowledges each chunk.
- A failed chunk is re-sent.
- After **5** failures the transfer stops, in both directions.
- An acknowledgement not received within **10 seconds** counts as a failure.
- Maximum file size **128 MB**.
- Keep the transfer's progress tracked internally, but keep the chunk traffic
  itself out of the conversation view.

  *Open question:* whether "hide this progress on UI" means no progress
  indicator at all, or only that the raw protocol messages must not appear as
  chat lines. A transfer with no visible progress and no way to cancel would
  be hard to tell apart from the app having frozen.

### The problem to solve before building this

**The size limits and the transfer mechanism are, as specified, about four
orders of magnitude apart.** The arithmetic, using this codebase's own
numbers:

- Outgoing messages are capped at 400 characters
  (`MAX_MESSAGE_CHARS`, `conn/actor.rs`).
- The send limiter sustains 0.5 messages per second after a burst of 5
  (`SendLimiter::DEFAULT_PER_SEC`, `conn/ratelimit.rs`). That rate is not
  arbitrary caution — it is roughly what servers tolerate before treating a
  client as flooding.

So base64 turns 128 MB into ~179 M characters, which is ~447,000 chunks, which
at one message every two seconds is **about ten days** — before counting a
single acknowledgement. The same sum puts a 1 MB image at ~2 hours and a
200 KB avatar at ~23 minutes.

Sending files as chat messages therefore cannot work for anything larger than
a few kilobytes, at any rate a server will tolerate. Two directions worth
weighing before writing the protocol:

- **DCC**, the established IRC answer: peers negotiate in-band, then open a
  direct TCP connection and send the file over that, subject to no message
  rate limit at all. Its weaknesses are well known — it exposes IP addresses
  and struggles with NAT — but it is what other clients implement and
  interoperate with.
- **Out-of-band upload**, where the file goes to a host over HTTPS and only a
  link travels over IRC. Simplest to build, but adds a service to run.

Most of the specification above — the handshake, the hashes, the chunking, the
acknowledgements, the metadata stripping, the failure limits — survives either
choice. What changes is what carries the bytes.

## Done

Kept here rather than deleted, because each one records a decision that would
otherwise have to be made again.

### Keep running in the background

- ✅ **Stay connected while the app is not the thing in front.** Off by
  default, on Windows, Linux, macOS and Android. ⛔ **Not on iOS**, on purpose.

  Three platform integrations wearing one checkbox, and the question of what it
  *means* on each turned out to matter more than the code.

#### Desktop: a window that hides, and a way back

  There was nothing to keep alive. The connections live in the Rust core, on
  its own threads, inside this process — hiding a window does not stop a
  process, so a hidden window is already a connected one. What was missing was
  the two halves of a door: a way to close the window without ending the
  process, and a way back in afterwards.

  The tray icon is the second half and is not decoration. It goes up with the
  setting and comes down with it, so there is no arrangement in which the
  window can hide with no icon to bring it back. Left-click restores, from
  minimised as well as hidden — a window shown while still minimised looks
  exactly like the click having done nothing. Right-click offers *Show* and
  *Quit*, and nothing else: everything else the app can do it does better in
  its own window, and a tray menu that grows into a second interface is a
  second interface to keep in step.

  The tooltip says how many networks are connected, and says "not connected"
  as plainly as it says a number. An icon that mentions connections only when
  it has some says nothing by its silence, and believing you are still on a
  network when you are not is the failure worth catching.

  **Closing is always intercepted, whichever way the setting is set.** The
  setting decides between hiding and quitting; it does not decide who is in
  charge of the close button. That is what closed a gap that predated this
  work: quitting used to end the process without telling anyone, so every exit
  looked like a ping timeout to everyone in the channel. Now both paths close
  the connections first — verified against the dev server, which logs
  `quit : ddirc_ui is no longer on the server` at the moment the window shuts.

  Off by default, because closing a window and having the app keep running is
  not what closing a window means anywhere else. The first time it happens it
  has to be something the user chose, not something they discover by finding
  the app still connected an hour later.

  One new Dart dependency, `tray_manager` — the companion to `window_manager`,
  which was already here. The tray icons are drawn by `make icons` from the
  same `MarkSpec` as everything else, so they cannot drift from the taskbar
  icon beside them; macOS gets a menu-bar template rather than the colour mark,
  since the menu bar recolours what it is given.

#### Android: permission to go on existing

  Nothing here holds a connection either. What differs is that the process is
  not ours to keep: an app the user is not looking at is a cached process, and
  a cached process is the first thing killed when memory runs short. So the
  thing to arrange is not a window that refuses to close but permission to
  exist, which is what a foreground service is — and the price Android charges
  is a notification.

  Worth paying openly. An app holding a socket open while nobody is looking at
  it *should* be visible, and the notification does the tray icon's job: it
  says the app is running, says how many networks are connected in the same
  sentence the tooltip uses, and carries the same Quit.

  **A swipe from Recents still closes it, and the setting says so.** That
  gesture means "close this", so the service honours it rather than outliving
  it. Surviving it would mean caching the Flutter engine outside the activity,
  and an app the user cannot dismiss is not the feature that was asked for.

  `specialUse` rather than `dataSync`, which is the type that looks like the
  obvious fit. From Android 15 a `dataSync` service is cut off after six hours
  in any twenty-four, which for a client whose purpose is to still be connected
  this evening is not a limit but a silent failure. The manifest carries the
  justification Google Play asks for at review; moving back is one string if it
  is ever refused.

  The notification permission is asked for and its answer ignored, deliberately.
  From Android 13 it can be refused, and refusing it costs being *told* the app
  is running — not the running itself. That is the user's call, and not a reason
  to withhold the thing they just switched on.

  **No new dependency.** The notification, the channel and the permission are
  framework APIs behind version guards. The status-bar icon is the same
  silhouette macOS gets, for the same reason: Android keeps only its alpha.

  Built and inspected, not run — there is no Android device here. The APK
  compiles, the Rust core cross-compiles for every ABI, and the merged manifest
  carries the three permissions and the service. Everything above the channel
  is covered by tests; what has not happened is a phone.

#### iOS: nothing, and that is the answer

  The OS will not hold a TCP socket open for an app that is not in front. The
  honest behaviour is to reconnect on returning to the foreground, and for the
  switch not to appear at all — which is what it does. A control that cannot
  keep its promise is worse than no control.

### Logging

- ✅ **Save logs and debug logs**, as an app setting. Optional, off by default.

  Two independent switches, both off until asked for. Chat logs record what was
  said; debug logs record connection and protocol events and never message
  content, so turning on the one needed to chase a bug does not also start
  recording conversations.

  Written to `logs/` inside the app's own private data folder — on Windows
  that is `%APPDATA%\dev.ddirc\ddirc\logs\`, beside the settings file; on
  Android it is app-private internal storage, deliberately not Documents or
  external storage, which are readable by anything holding the storage
  permission. The folder is shown in settings before either switch is turned
  on, and is not created until there is a line to write.

  Each file is capped at 5 MB with one rotated copy kept, so the pair has a
  ceiling a user can reason about. A `redact` pass blanks anything shaped like
  a credential on the way into the debug log — a backstop, since the core
  strips secrets before they become events.

### Error messages

- ✅ **Say what actually went wrong.** Done alongside the logger, because a
  debug log full of "an io error occurred" would have been worth nothing.

  The `irc` crate's `Display` for its commonest error is exactly that string,
  with the underlying `io::Error` attached as a source it never prints — so a
  mistyped hostname, a firewall, a wrong port and a server that is down all
  arrived identical and unactionable. `conn/diagnose.rs` classifies them
  instead, names the host and port, and says what usually fixes it.

  On the Dart side `AnyhowException.toString()` is `AnyhowException(msg)` —
  parentheses, not a colon — so the strip that was meant to remove the wrapper
  never matched, and users saw it. Unwrapped by type now, in
  `model/errors.dart`.

### Show the proxy in the main window

- ✅ **Every connection says how it reached its server.** The network rail's
  tooltip, and a `Route` row in Server settings beneath `Transport`.

  Both read the proxy from the config the connection was *opened with*, not
  from the current settings — those can change while a connection is up, and
  the gap between them is what this exists to expose.

  It says "Connected directly" as plainly as it names a proxy. A label that
  appears only when a proxy is in use says nothing by its absence, and
  believing a connection is proxied when it is not is the failure worth
  catching. An unconnected profile gets no route line: nothing has been
  reached, so there is nothing true to say.

### Auto-connect

- ✅ **Connect this network at launch.** Off by default, and off for every
  profile saved before the flag existed.

  Marked networks are opened all at once and none of them awaited, so a server
  that is down cannot hold up the others or the first frame — measured at 1.2 s
  to a usable window with the marked server refusing connections, the failure
  reported inline where the user would look anyway.

  Which network you land on is decided up front rather than by whichever
  connection wins the race: the first marked profile in saved order takes the
  selection, and if it fails, whichever else arrives first is shown so a launch
  that connected *something* never lands on an empty screen.

### Strip metadata before sending

- ✅ **The stripping, and everything up to the send path.** ⛔ **The send path
  itself** — blocked with the rest of *Sending media*.

  Reachable from the app now: `clean_media` across the FFI, `MediaCleaner` in
  Dart, and a setting that is **on by default** — the only privacy switch here
  that is, because the others decide whether to keep something the user already
  has and this one decides whether a stranger gets the coordinates of a room.

  Four outcomes rather than a boolean, because the caller has a different
  decision in each: cleaned, already clean, not an image, damaged. A file
  nothing could be removed from is sent anyway and says so — refusing to send a
  document because it is not a JPEG would answer a question nobody asked — but
  it is flagged, because that is the case where the protection quietly did not
  apply.

  No settings switch yet, deliberately. A control that says "before sending"
  in an app that cannot send images would promise something that is not there.

  `media/` removes EXIF, XMP, IPTC/Photoshop blocks, text chunks, comments,
  embedded thumbnails and timestamps from JPEG, PNG, GIF and WebP, and reports
  what it took out so the UI can say rather than merely claim.

  Every format is rewritten as a container with the image data copied across
  untouched, so the pixels come out byte-identical. Decoding and re-encoding
  would lose quality on every JPEG to delete a text field, and would want an
  image codec in the dependency tree; this needs neither. Nothing was added to
  `Cargo.toml`.

  Colour profiles, JFIF density and Adobe's colour-transform marker are kept on
  purpose. They change how the image *renders* — remove them and the recipient
  sees different colours from the sender — and they name a colour space rather
  than a person. GIF's looping declaration is kept for the same reason: an
  animation that stops after one pass is a changed image, not a cleaned one.

  Verified against files written by real imaging software carrying real GPS,
  camera and software fields: every one decodes afterwards, with identical
  pixels, no metadata the decoder can find, and none of the original strings
  anywhere in the bytes. `tests/media_files.rs` runs it over a directory of
  your own photographs.

### `.onion` addresses

- ✅ **Reach onion services**, with certificates verified exactly as anywhere
  else.

  Almost nothing had to be built. SOCKS5 already resolves the destination name
  at the far end, so an onion address travels to Tor untouched; TLS is then
  negotiated and verified against that name like any other host. Proved by
  registering on a real onion service over real Tor, with no bypass anywhere.

  The open question — what certificate verification should mean for a name
  that is itself a public key — is answered by not changing anything. Tor
  authenticates *which service* answered, but it says nothing about the
  connection above it, and relaxing the check would mean trusting the proxy to
  be Tor when nothing here can know that it is. An onion service reachable
  from ddIRC is one holding a certificate for its own `.onion` name, which is
  permitted and is the only arrangement that does not weaken the client.

  Two things were added, both about saying so: an onion address configured
  without a proxy is refused at validation, because the alternative is a DNS
  failure that names DNS — accurate and useless for a name that is not in DNS
  and never will be. And a certificate failure on an onion address names the
  fix specific to onions rather than the generic self-signed advice.

  `make dev-tor` publishes the dev server as an onion service; `make
  dev-onion-cert` issues it a certificate for that address.

### Proxy

- ✅ **Proxy, per server**, and ✅ **a global proxy setting** in app settings.
  Both off by default.

  The open question is settled: global is the default, and a server may
  override it. Three choices per network — App default, Direct, Custom — rather
  than a switch, because "off" and "not set" are different answers. A network
  that must never be proxied has to be able to say so, or turning on the
  app-wide proxy would sweep it up with everything else. The alternative, a
  global proxy admitting no exceptions, was rejected: it makes one network's
  requirements break every other network with no way to see why.

  SOCKS5 only. It is what the transport supports, and it is the right first
  choice anyway — it carries arbitrary TCP and resolves the destination name at
  the far end, so a proxy meant to hide where you are is not undone by a DNS
  lookup from here.

  TLS is still negotiated end to end with the IRC server through the tunnel, so
  the proxy carries ciphertext it cannot read. There is no direct-connection
  fallback: a proxy that cannot be reached fails the connection.

  `make dev-proxy` and `make dev-tor` bring up a fixture for each half.
