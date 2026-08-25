# TODO

Ordered easiest first. Everything left carries either a new dependency, a
per-platform decision, or an unanswered question.

Everything here ships **disabled by default**. Items marked **beta** should
additionally be labelled as such in the UI.

## 1. Keep running in the background

- **Stay connected with the window closed.** Off by default.

  Three separate platform integrations rather than one feature: a tray icon
  and a hidden window on desktop, a foreground service and its notification on
  Android, and on iOS most likely nothing at all, since the OS will not hold a
  socket open for an app that is not in front. Worth deciding what it means on
  each before building any of them.

## 2. Built-in Tor — beta

- **Ship Tor rather than expect it.** Research first: Arti is the Tor Project's
  own Rust implementation, published as the `arti-client` crate, so this would
  be a dependency rather than a bundled `tor` binary.

  Worth establishing during the research: whether Arti's embedded mode is
  ready for a shipping client, what it adds to the binary size and startup
  time, and how the licence interacts with app-store distribution.

  Note that half of this already works, and is tested. Anyone running Tor
  themselves can point the proxy setting at `127.0.0.1:9050` today — the form
  starts on that port for exactly that reason — and `make dev-tor` brings up a
  real Tor for exercising it. What is left is bundling it, so that using Tor
  does not first require installing Tor.

## 3. A local IRC server — beta

- **Run an IRC server inside the app**, so a user can host a small network
  without a separate daemon.

  Undecided: whether it listens beyond loopback, and if so what its TLS story
  is. The client requires TLS with no bypass, so a local server that only
  speaks plaintext would be unreachable from ddIRC itself — the same
  constraint that shaped `dev/`.

## 4. Sending media — beta

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

- ✅ **The stripping itself.** ⛔ **Wiring it to a send path** — blocked with
  the rest of *Sending media*, because there is nothing to send with yet.

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
