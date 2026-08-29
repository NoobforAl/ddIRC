# Security posture

ddIRC treats **everything a server sends as untrusted**. IRC has no message
authentication, servers are operated by strangers, and any user on a channel can
choose the exact bytes that reach your client.

## What the Rust core removes by construction

The original C design carried a checklist that had to be enforced by discipline
on every line written. Moving the core to safe Rust retires most of it outright:

| Original requirement | Status |
|---|---|
| No `strcpy`/`sprintf` into fixed buffers | Not expressible — no fixed buffers, no manual copies |
| No format-string bugs | Not expressible — `format!` takes a literal template |
| Explicit lengths across the FFI boundary | Handled by generated bindings, not hand-written marshaling |
| Validate null-termination before making strings | Rust strings carry their length |

`ddirc-core` declares `#![forbid(unsafe_code)]`. Any `unsafe` the FFI layer
needs is confined to generated code.

## What still requires care

### Transport

- **TLS is mandatory and not configurable.** `use_tls` is hardcoded to `true`.
- **`dangerously_accept_invalid_certs` is never plumbed to the API.** There is no
  path through the code that skips certificate verification.
- Roots come from `webpki-roots` *plus* the platform store. The bundled Mozilla
  set is added first, so TLS still verifies on Android even where the native
  store is unreadable.
- **`ServerConfig::extra_root_cert` adds a root; it never replaces the store or
  skips verification.** It exists so integration tests can reach the self-signed
  dev server in `dev/`, which is the alternative to a verification-skipping
  switch existing at all. It is not reachable from the app: the FFI layer's own
  `ServerConfig` has no such field, so nothing Dart can set reaches it. An
  unreadable path is rejected at config validation rather than being silently
  ignored, which is what the `irc` crate does on its own.
- Conventional plaintext ports (6660–6669, 194) are **rejected at config
  validation** with an explanation, rather than failing later as an opaque
  handshake error.

### Proxy

Off by default. SOCKS5 only, and every property below is a deliberate one.

- **The proxy carries the connection; it does not terminate it.** The SOCKS5
  tunnel is opened first and TLS is negotiated end to end with the IRC server
  through it, verified against the server's own name with the same code path a
  direct connection takes. The proxy sees ciphertext to a host it was told
  about. It cannot read the stream and cannot substitute itself for the server.
- **There is no direct-connection fallback.** A configured proxy that cannot be
  reached fails the connection. Falling back would defeat the one thing a proxy
  exists for, at the moment it mattered most, and would do so silently.
- **The destination name is resolved at the proxy.** SOCKS5 is given the
  hostname rather than an address, so nothing on this machine looks up where the
  user is about to connect. This is the reason for SOCKS5 over an HTTP proxy,
  and it is what makes the setting usable with Tor.
- **The proxy is resolved in Dart, once, before the config crosses the FFI.**
  The core is handed one answer — a proxy or none — rather than a policy to
  interpret, so there is no second place where a per-server override could be
  read differently from the app-wide setting.
- **A per-server "Direct" choice is explicit.** It is a selected option, not an
  empty field, so a network is never exempted from the proxy by accident. The
  editor says plainly that such a network will still see the user's address.
- **Proxy credentials live in the platform keychain**, alongside the SASL
  password and never in `shared_preferences`. On the Rust side they are held in
  `Zeroizing` and validated to SOCKS5's 1–255 byte range before use. RFC 1929
  sends them to the proxy in the clear, before any TLS exists; the UI says so
  where they are typed, because a credential whose exposure is not obvious is
  one a user will reuse.
- **Onion addresses are verified like any other host.** No relaxed mode, no
  exception. Tor authenticates which service answered, but it says nothing
  about the TLS session inside the tunnel, and relaxing the check would mean
  trusting the proxy to be Tor when nothing in the client can establish that.
  An onion service reachable from here is one holding a certificate for its own
  `.onion` name. An onion address configured without a proxy is refused at
  validation, since it cannot resolve and the resulting DNS error would explain
  nothing.
- **Half a credential is rejected at config validation.** A lone username
  otherwise reaches the transport, which refuses it with a message about byte
  lengths that names the wrong problem.

### Secrets in memory

- **Passwords are held in `Zeroizing`**, so they are wiped on drop rather than
  left in freed heap memory. This covers the SASL, NickServ, server and proxy
  passwords.
- **`ServerConfig` and `ProxyConfig` implement `Debug` by hand**, redacting
  every secret. The derived implementation printed all four in full. Nothing
  formats a config today, but `Zeroizing` wipes a secret when it drops and does
  nothing about one already written into a log line — and the app now has a
  debug log.
- One copy is unavoidable: the `irc` crate's own config takes the proxy and
  server passwords as plain `String`, which is not zeroized on drop. Noted here
  rather than papered over; removing it would mean vendoring the crate.

### Outgoing files

- **Image metadata is removed by rewriting the container, never by
  re-encoding.** `media/` drops EXIF, XMP, IPTC, text chunks, comments,
  embedded thumbnails and timestamps from JPEG, PNG, GIF and WebP. The image
  data is copied across byte-identically, so nothing is lost to a re-compress
  and no image codec enters the dependency tree.
- **A file it cannot parse is refused, not passed through.** Reporting a file
  as cleaned when its format was not understood would be the one failure that
  matters here, so an unknown or malformed file returns an error and leaves the
  decision to the caller.
- **What was removed is reported**, so the UI can say what left the file rather
  than asking the user to trust that something did.
- **The parsers cannot panic.** They are handed whatever file the user picked,
  which includes truncated and mislabelled ones. Every read is bounds-checked,
  lengths are added with checked arithmetic, and the tests sweep every
  truncation and every single-byte corruption of a valid file of each format.
- Deliberately kept: colour profiles, JFIF density, Adobe's colour-transform
  marker, and GIF looping. These change how an image renders rather than saying
  anything about a person, and removing them would alter what the recipient
  sees.

### File transfers

Off by default. With the setting off, no offer is shown and there is no way to
send one.

- **A DCC offer carries an address, and that is stated rather than hidden.**
  Sending asks every time, names who will learn the address, and says plainly
  that offering to a channel tells everyone in it. The dialog cannot be
  suppressed, because the property it reports never stops being true.
- **A transfer discloses no more than the connection that negotiated it.** With
  a proxy configured, an incoming offer is dialled *through* the proxy, and
  anything that would require us to listen — an incoming reverse offer, or
  sending at all — is **refused with a reason**. There is no direct-connection
  fallback anywhere on this path, for the same reason there is none on the IRC
  path: a fallback is what would defeat the proxy at the moment it mattered.
- **Declining is silent.** Nothing is sent back, so a stranger fishing for a
  live client learns nothing from being refused.
- **The UI never hands an address back to the core.** An offer is accepted by
  the id it was announced with, so the only addresses ever dialled are ones the
  core parsed itself.
- **Nothing is overwritten.** A name already taken is an error. Incoming files
  are written under a `.part` name and renamed only once whole, so a failed
  transfer cannot be mistaken for the file it was going to be, and filenames go
  through `safe_filename` so a sender cannot escape the directory.
- **Received files land in app-private storage**, beside the logs — not the
  system Downloads folder. A file somebody else chose does not belong among the
  ones the user fetched themselves, and on Android shared storage is readable
  by anything holding the storage permission.
- **The size in an offer is the sender's claim.** The 4 GB ceiling is enforced
  against the bytes that actually arrive, so an understated size cannot become
  permission to fill a disk.
- Sending runs the file through the metadata stripper above first, and the
  confirmation reports what was actually removed from *that* file. A cleaned
  copy that cannot be written means the send is refused, never that the
  original goes instead.

### Untrusted server data

- **Control codes are stripped in Rust, not Dart.** `text/format.rs` parses mIRC
  formatting into styled spans whose text is guaranteed free of C0 characters
  and DEL. A malicious message cannot inject line breaks, break the layout, or
  forge the styling reserved for system messages. Doing this in the core means
  the defence cannot be forgotten by a future UI change.
  Tab is stripped too — it can fake the indentation of a system line.
- **Every collection is bounded.** Channels (512), members per channel (20 000),
  topic (1 000 chars), nick (64), channel name (200). Exceeding a bound stops
  growth rather than dropping the connection.
- **Capability lists are bounded** (8 KiB). A server can otherwise stream
  `CAP LS *` continuation lines forever during negotiation.
- **Unknown channels are ignored.** A `JOIN` for a channel we never joined does
  not create state.
- **MODE parameters are re-aligned** against the server's `CHANMODES` rather than
  trusting the crate's hardcoded table, which is wrong for `-l`. Mis-alignment
  would attribute channel privileges to the wrong member.
- **SASL cannot be restarted.** Once negotiation concludes, further messages are
  ignored, so a replayed `903` cannot drive the client back into authenticating.

### Outgoing data

- **Newlines are split, never sent.** A message containing CRLF would otherwise
  inject arbitrary commands into our own session. Each line becomes the
  parameter of its own `PRIVMSG`.
- Messages are chunked to 400 characters on character boundaries, below the
  512-byte IRC line limit.
- Nicknames containing whitespace or control characters are **rejected at config
  validation**, closing the same injection vector during registration.

### Unsolicited messages

Anyone on IRC can message anyone. A first message from a nick with no
conversation is therefore treated as a **request**: it is stored and shown, but
it opens no tab, never takes the screen, and the composer is replaced by
*Accept* and *Decline* until it is answered.

The reason the composer is shut rather than merely discouraged is that **any**
reply — including a refusal — confirms a live client on the other end, which is
most of what an unsolicited message is fishing for. Declining sends nothing.

Declining blocks that nick on that network. The check runs in
`SessionModel._onEvent` before anything else, so a blocked message never reaches
a conversation, an unread count, or a log file — a block that left a trace would
be one the user has to tidy up after. Blocks are per profile and folded to lower
case, because IRC nicks are case-insensitive and a block `Alice` could step
around by capitalising is not a block.

### Notifications

A notification is drawn by the operating system, may persist on a lock screen,
and cannot be taken back once shown. So what it is allowed to say is a privacy
decision, not a presentation one.

- **Sender and network only, by default.** The message text is behind a setting
  that is **off**, matching how chat logs are treated: content the app cannot
  retrieve is not written anywhere without being asked for.
- **Never a stranger's words.** A request from an unaccepted nick shows only
  that they want to message you, even with the preview setting on. Otherwise an
  unsolicited message would be read on the lock screen regardless of the answer.
- **Never ordinary channel traffic.** Only a direct message or a mention of the
  nickname; a per-conversation level can narrow that further but never widen it.
- Nothing is sent anywhere to make one. Both paths are local — the platform's
  own API on desktop, and `MainActivity`'s own `NotificationManager` on Android.
  There is no push service, no token, and no third party involved.

### CTCP

Only `ACTION` is treated as chat. Every other CTCP request — `VERSION`, `TIME`,
`PING`, `FINGER`, `SOURCE`, `USERINFO` — is **ignored rather than answered**.
Replying would leak client version, platform, and local timezone to anyone who
asks.

`DCC SEND` is the one request that is recognised, and recognising it is not
answering it: an offer becomes an event for the user to decide about. Nothing is
sent back and no connection is made.

This holds in two places, and it has to hold in both. Our own handler
(`conn::actor::on_ctcp`) drops everything else in silence — but the `irc` crate
underneath has a `ctcp` feature which, when enabled, answers CTCP *itself* from
inside `ClientStream::poll_next`, using its own sender, before our code is
reached. It was enabled, and it was replying: `FINGER` with the real name and
username, `VERSION` with the crate's version string, and `TIME` with
`Local::now()` in RFC 2822 — the machine's wall clock and its UTC offset, handed
to anyone who sent a `PRIVMSG`. The feature is now off, nothing in this
workspace needs it, and a test asserts it stays off, because the leak lives
below the layer the behavioural tests can see.

### Rate limiting

Both directions, via token bucket:

- **Outgoing** — burst of 5, then one message per two seconds. Servers disconnect
  clients that send too fast; we pace ourselves rather than relying on the server
  to be forgiving.
- **Incoming** — burst of 200, then 50/sec. Excess is dropped **and counted**, and
  the count is surfaced to the UI, so a gap in a conversation is never silently
  mistaken for silence.

Events are dropped rather than awaited when the UI falls behind. Blocking there
would stop us reading the socket and the server would eventually ping-timeout us.

### Reconnection

Exponential backoff (2s base, 300s ceiling) with **equal jitter** — always at
least half the window, plus a random draw over the rest.

Full jitter was tried first and rejected: it can return a near-zero delay, and
against a server actively refusing us (a K-line, a DNSBL listing) that produces a
burst of immediate retries that looks like an attack. This was caught in live
testing, where a rejected connection retried in under a second.

Backoff resets only on **successful registration**, not when the socket opens. A
server that accepts and immediately drops us would otherwise reset the backoff
every cycle and produce a hot loop.

### Credentials

- Held in `Zeroizing<String>`, so they are wiped when dropped rather than left in
  freed heap memory.
- The assembled `IDENTIFY` line is zeroized too, not just the password.
- Dropped from the SASL negotiator as soon as authentication resolves, rather
  than held for the connection's lifetime.
- `Credentials` has a hand-written `Debug` that prints `<redacted>`, so a stray
  `{:?}` cannot leak a password into logs.
- The CLI harness reads secrets from the environment, never argv, and **removes
  them from its own environment** after reading so they are not inherited by
  child processes.
- In the app, a profile's SASL password lives in `flutter_secure_storage`
  (Android Keystore; DPAPI on Windows), keyed by the profile's id. It is read
  at connect time, handed straight to the core, and never stored on the
  in-memory `Profile` object — so a profile list dumped for any reason cannot
  carry a credential. Deleting a profile deletes its stored password.
- The settings store (`shared_preferences`) holds **display preferences only** —
  booleans, an enum, and per-channel notification levels. It is plain,
  world-readable-by-the-app storage with no encryption, so nothing that
  authenticates the user goes in it: no password, ever. It does hold the saved
  profiles — network name, host, port, nickname, channels, and the SASL account
  *name* — plus per-channel notification levels. That is a record of which
  networks a user joins and under what nick, so it is not nothing; it is
  ordinary configuration rather than a credential, and it is what a plain
  config file would hold on any other client.

### Least privilege

`api/` is the entire public surface. No `irc`-crate type is re-exported, so the
UI cannot reach a socket, a session handle, or protocol internals — and we stay
free to vendor or replace the underlying crate without touching Dart.

## Dependencies

`Cargo.lock` is committed. Run `cargo audit` over the full tree:

```bash
cd irc-core && cargo audit
```

This is a strict improvement on the original plan's "manually watch for
advisories on an unmaintained C library": RustSec covers every transitive
dependency automatically.

### Known advisories

| Advisory | Crate | Assessment |
|---|---|---|
| RUSTSEC-2025-0134 | `rustls-pemfile` 2.2.0 | **Informational — unmaintained, not a vulnerability.** Reached only through the `irc` crate's `cert_path` PEM loading, which is set only by `ServerConfig::extra_root_cert` — a field the integration tests use and the app cannot set. Not on any code path a shipped build reaches. |

## Reporting

This is a personal project without a formal disclosure process. Open an issue,
or for anything sensitive, contact the maintainer directly rather than filing
publicly.
