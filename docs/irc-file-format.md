# The `.irc` network config format

A `.irc` file is a small YAML document naming one or more IRC networks. It is
what **Add network → Import a `.irc` file** reads, and it is also, verbatim,
what **Add network → Scan a QR code** expects a QR code to decode to. One
format, one parser, two ways in.

The format **reads passwords and never writes them.** That asymmetry is
deliberate, and it is the thing to understand before writing one by hand:

- A file you write **can** carry a password, so a network arrives complete —
  paste it in, import once, done. See [Passwords](#passwords).
- A file the app **exports** never carries one, and neither does a QR code it
  produces. Export is for moving a network between your own devices or handing
  it to somebody else, and that is a different act with a different audience.

So a password crosses in and never back out. The one you write into a file is
the only copy sitting in the clear, and it is yours to delete.

Reference implementation: [`lib/src/model/ircconfig.dart`](../lib/src/model/ircconfig.dart).
Round-trip tests: [`test/ircconfig_test.dart`](../test/ircconfig_test.dart).

---

## The shortest file that works

```yaml
ddirc: 1
networks:
  - name: 'Libera.Chat'
    host: 'irc.libera.chat'
    port: 6697
    nickname: 'ddirc'
    channels: ['#ddirc']
```

Save it as `something.irc` and import it. That is the whole format; everything
below is detail.

---

## Structure

| Key | Type | Required | Meaning |
| --- | --- | --- | --- |
| `ddirc` | integer | no (write it anyway) | Format version. Currently `1`. The exporter writes it; the reader does not yet enforce it, and a future version may. |
| `networks` | list of mappings | **yes** | The networks. Must be present and non-empty, even for a single network. |

Anything else at the top level is ignored.

`networks` is a list even when it holds one entry. A QR code that could only
ever encode a single network would have become a second format the first time
somebody wanted to share two.

### Fields of one network

| Key | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `host` | string | **yes** | — | Hostname or IP. A `.onion` address is fine when a proxy is in play. |
| `port` | **integer** | **yes** | — | Must be an unquoted whole number. See [TLS is not optional](#tls-is-not-optional). |
| `nickname` | string | **yes** | — | |
| `name` | string | no | the `host` | What the network is called in the UI. Its initials become the rail badge. |
| `altNicks` | list of strings | no | `[]` | Tried in order if the nickname is taken. Empty means the app falls back to `<nickname>_`. |
| `channels` | list of strings | no | `[]` | Joined on connect. **Must be quoted** — see [`#` is a YAML comment](#-is-a-yaml-comment). |
| `saslAccount` | string | no | none | Account name. Pair it with `saslPassword`. |
| `password` | string | no | none | **Import only.** Sent as the server's `PASS`. Alias of `serverPassword`. |
| `serverPassword` | string | no | none | **Import only.** The explicit spelling; wins if both are given. |
| `saslPassword` | string | no | none | **Import only.** The password for `saslAccount`. |
| `nickservPassword` | string | no | none | **Import only.** Used if SASL was not accepted. |
| `proxyMode` | `followDefault` \| `direct` \| `custom` | no | `followDefault` | Where this network's proxy comes from. |
| `proxy` | mapping | no | none | This network's own SOCKS5 proxy. Only used when `proxyMode: custom`. |
| `proxy.host` | string | yes, within `proxy` | — | |
| `proxy.port` | integer | yes, within `proxy` | — | |
| `proxy.username` | string | no | none | The proxy password lives in the keychain, not here. |
| `autoConnect` | boolean | no | `false` | Connect this network at app launch. Must be an unquoted `true`. |

Unknown keys are ignored, so a file written by a newer version of the app still
imports into an older one — it just loses whatever the older one does not know
about.

**`id` is deliberately not a field.** The exporter writes none, and if you add
one it is discarded: every imported network is given a fresh local id. That id
keys a keychain entry on the device that holds it, and carrying one across
devices would risk two unrelated networks ending up addressed by the same key
on a third.

### A file using everything

```yaml
ddirc: 1
networks:
  - name: 'Libera.Chat'
    host: 'irc.libera.chat'
    port: 6697
    nickname: 'ddirc'
    altNicks: ['ddirc_', 'ddirc__']
    channels: ['#ddirc', '#offtopic']
    saslAccount: 'alice'
    autoConnect: true

  - name: 'OFTC over Tor'
    host: 'oftcnet6xg6roj6d7id4y4cu6dchysacqj2ldgea73qzdagufflqxrid.onion'
    port: 6697
    nickname: 'ddirc'
    proxyMode: 'custom'
    proxy:
      host: '127.0.0.1'
      port: 9050

  - name: 'LAN bouncer'
    host: '192.168.1.10'
    port: 6697
    nickname: 'ddirc'
    proxyMode: 'direct'
```

---

## The QR code

There is **no separate QR format**. The payload is the text of a `.irc` file,
byte for byte, as plain UTF-8 text. No base64, no compression, no `ddirc://`
URL wrapper, no JSON envelope around it.

The app **scans** QR codes but does not currently **generate** them — export
gives you a `.irc` file (the save icon in the network editor), and you make a
QR from that text with any generator you like.

To make one that scans:

1. Export or write the `.irc` text.
2. Paste it into a QR generator in **plain text / raw text** mode — not
   vCard, not URL, not Wi-Fi.
3. Check the generator did not smarten the quotes, strip the newlines, or
   append a tracking URL. Several "free QR" sites do all three.
4. Scan it back with the app before relying on it.

### Keep it small

QR capacity tops out around 2,953 bytes, and long before that a code becomes
too dense for a phone camera pointed at another screen. Practical guidance:

- **One network per QR code.** Multi-network files belong in a file.
- Drop everything optional. `host`, `port`, `nickname` and `name` are usually
  enough; the recipient can type the rest.
- Aim for **under ~400 characters**. That keeps the module count low enough to
  scan across a room, off a laptop screen, or from a printed page.
- Use error-correction level **L** or **M**. Level H buys robustness you do not
  need at the cost of density you cannot afford.

The scanner reads the **first** barcode it decodes and closes. Structured-append
(multi-part) QR codes are **not** supported; a two-part code will import
whichever half was scanned, if it parses at all, and otherwise fail.

### JSON is valid YAML

For a QR code specifically, compact JSON is a legitimate `.irc` payload and is
noticeably shorter:

```json
{"ddirc":1,"networks":[{"name":"Libera","host":"irc.libera.chat","port":6697,"nickname":"ddirc","channels":["#ddirc"]}]}
```

It parses identically — the reader is a YAML parser, and YAML is a superset of
JSON — and it survives generators that mangle newlines, because it has none.
Prefer indented YAML for files a human will open, compact JSON for QR codes.

---

## Why your file might not work

These are ranked by how often each one is actually the problem.

### TLS is not optional

**ddIRC connects over TLS. Always. There is no plaintext mode and no field in
this format to ask for one.**

If you wrote `port: 6667`, the import succeeds, the network appears, and the
connection fails — the app speaks TLS at a port that answers in cleartext. Use
the network's **TLS** port, which is `6697` on nearly every network.

This is the single most common cause of "the file imported but it won't
connect".

### A wrong type is silently dropped

`host`, `port` and `nickname` are checked, and `port` must be an **integer**.
Every one of these drops the network on the floor without an error:

```yaml
port: '6697'      # a string, not an integer — entry dropped
port: 6697.0      # a float — entry dropped
port: "6697"      # same problem, different quotes
```

A dropped entry is not a failure. If it was the *only* entry, the import dialog
opens saying **0 found** with nothing to tick — which is what "I made a file but
nothing happens" looks like. If your import comes up empty, check `port` first.

The same silent drop applies to a network missing `host` or `nickname`
entirely. That tolerance is deliberate: a shared file naming five networks
should not be refused over one bad line.

### Wrong key names

The keys are exactly as spelled in the table above, and they are
**case-sensitive camelCase**. These are all ignored:

```yaml
server: irc.libera.chat    # it is `host`
nick: ddirc                # it is `nickname`
altnicks: [...]            # it is `altNicks`
sasl_account: alice        # it is `saslAccount`
auto_connect: true         # it is `autoConnect`
tls: true                  # no such field; TLS is always on
password: hunter2          # no such field, by design — see below
```

Get `host` or `nickname` wrong and the entry is dropped. Get an optional one
wrong and it is quietly ignored — the network imports, just without that
setting.

### `#` is a YAML comment

In YAML, an unquoted `#` starts a comment. A channel list written bare will
either be eaten or fail the whole file:

```yaml
channels: [#ddirc, #offtopic]     # breaks the file outright
channels: ['#ddirc', '#offtopic'] # correct
channels:                         # correct, block form, still quoted
  - '#ddirc'
  - '#offtopic'
```

The exporter quotes every string unconditionally for exactly this reason. Do
the same when writing one by hand.

`channels` must also be a **list**. A bare string is ignored without complaint:

```yaml
channels: '#ddirc'      # silently becomes no channels
channels: ['#ddirc']    # correct
```

### Booleans must be bare

```yaml
autoConnect: 'true'   # a string — read as false
autoConnect: true     # correct
```

Anything that is not a literal `true` is `false`. A corrupted value therefore
fails safe: nothing connects on launch that you did not ask for.

### Tabs are not YAML

YAML indentation is **spaces only**. A tab produces a parse error and the whole
file is refused. If your editor inserts tabs, turn that off for `.irc`.

Two spaces per level, as in the examples, is what the exporter writes and what
reads most clearly.

### The proxy is ignored unless the mode says so

```yaml
proxy:                 # present, and completely unused —
  host: '127.0.0.1'    # `proxyMode` still defaults to followDefault
  port: 9050
```

`proxy` is only consulted when `proxyMode: custom`. Setting one without the
other imports cleanly and changes nothing. An unrecognised `proxyMode` value
also falls back to `followDefault` rather than failing.

Note also that built-in Tor, when enabled app-wide, overrides all three modes —
a per-network `direct` cannot route around it. That is deliberate.

### The password was there but nothing used it

Check the spelling against [the four names](#the-four-names). A misspelled
credential key is an unknown key, and unknown keys are dropped without
complaint — `sasl_password`, `saslPass` and `nickserv` all import a network that
then fails to authenticate.

The **Test connection** button on the import screen answers this directly: it
runs the real exchange with whatever is in the fields, so a password that was
never read shows up as *SASL did not authenticate you* before anything is saved.

Two credentials are deliberately not tested, and neither is a fault:

- **NickServ** is never sent by a test. Identifying to a service is a side
  effect, and a test is supposed to leave nothing behind.
- A **proxy password** is used by the test but has no field on the import
  screen. It comes from `proxy.password` in the file, or from the editor after
  importing.

---

## Passwords

A file you write by hand can carry every credential a network needs:

```yaml
ddirc: 1
networks:
  - name: 'Libera.Chat'
    host: 'irc.libera.chat'
    port: 6697
    nickname: 'ddirc'
    channels: ['#ddirc']

    password: 'hunter2'             # the server's PASS
    saslAccount: 'alice'
    saslPassword: 'hunter2'
    nickservPassword: 'hunter2'

    proxyMode: 'custom'
    proxy:
      host: '127.0.0.1'
      port: 9050
      username: 'bob'
      password: 'hunter2'           # the proxy's own
```

Import that and the network is complete — nothing left to type.

### The four names

| Key | Goes to |
| --- | --- |
| `password` **or** `serverPassword` | The server's `PASS`, sent before registration |
| `saslPassword` | SASL, paired with `saslAccount` |
| `nickservPassword` | NickServ, used only if SASL was not accepted |
| `proxy.password` | This network's own SOCKS5 proxy — nested inside `proxy:` |

`password` and `serverPassword` are the same field. `password` is what the IRC
protocol calls it and what most other clients' configs call it; `serverPassword`
matches the label in ddIRC's own editor. Give both and the explicit one wins.

An **all-digit password needs no quotes** — `password: 123456` is read
correctly, unlike `port`, which really does need a bare integer. Quoting it is
still clearer.

An empty value (`password: ''`) is the same as writing nothing.

### They are import-only

Nothing writes these keys back out. Exporting a network produces a file with no
credential in it, and the round-trip test asserts the word `password` never
appears in exported text. Concretely:

- A `.irc` file **you** wrote may contain passwords.
- A `.irc` file **ddIRC** wrote never does, and neither does a QR code made from
  one.

On import each password goes straight to the platform keychain and the network
itself keeps none of it — see [Where the passwords actually are](#where-the-passwords-actually-are).

### What you are accepting

A `.irc` file with a password in it **is** that password, in plain text, on
disk. Nothing encrypts it. The same goes for a QR code made from one: it is a
password on a screen, in a room, readable by any camera pointed at it.

That is a reasonable trade for a file you wrote, keep locally, and delete after
importing. It is a bad one for a file you send to somebody, put in a repo, or
back up to a cloud drive — for those, leave the passwords out and let the other
person type their own. The import screen says as much when it sees credentials
in a file.

## Where the passwords actually are

Not in this file, and not in app settings either. Every one lives in the
platform keychain via `flutter_secure_storage`, keyed by the network's **local**
id — which is regenerated on import, so a keychain entry never follows a file
between devices.

| Password | Keychain key | Where you type it |
| --- | --- | --- |
| Server `PASS` | `server-pass.<id>` | Editor → Advanced → Authentication |
| SASL | `sasl.<id>` | Editor → Advanced → Authentication |
| NickServ | `nickserv.<id>` | Editor → Advanced → Authentication |
| Proxy | `proxy.server.<id>` | Editor → Advanced → Proxy |

The backend is whatever the OS provides — the app implements no encryption of
its own:

| Platform | Store | Key lives in |
| --- | --- | --- |
| Android | `EncryptedSharedPreferences`, AES-GCM | Android Keystore, hardware-backed |
| iOS, macOS | Keychain Services | Secure Enclave / effaceable storage |
| Windows | DPAPI | Your login credential |
| Linux | libsecret | The session keyring |

**Moving to a new Android phone does not carry them.** The Keystore key that
decrypts them is hardware-bound and cannot leave the device, so a restored
backup would arrive as ciphertext nothing can read. Rather than let that get
deleted silently — which looked like networks that were fine but would not
authenticate — the secret store is excluded from backup and device transfer
outright. The new phone starts with empty password fields, which is the same
end state said out loud. Apple's encrypted backup carries keychain items
properly and is not excluded.

Behaviour worth knowing:

- **Blank means "keep", not "clear".** Editing a network and leaving a password
  field empty preserves what is stored — the field's hint says
  *Stored — leave blank to keep it*. Clearing one takes saving an empty value
  deliberately.
- Each is read **only at connect time**, handed straight to the core, and
  zeroized once used. None is ever held on the in-memory profile, so a profile
  list dumped for any reason cannot carry a credential.
- Deleting a network deletes all four of its stored passwords.
- The SASL password is dropped automatically if the SASL account is cleared, and
  the proxy password if the proxy stops using authentication. The server and
  NickServ passwords have no companion field to check against, so they are only
  ever cleared explicitly.

Moving a network between two of your own devices: export it, carry the file
over, import it, then type the passwords once on the new device. The exported
file has none in it — if you want them carried too, write them into the file by
hand, and delete it afterwards.

---

## Error messages, and what each means

| What you see | What happened |
| --- | --- |
| *Not a valid ddIRC network config: …* | The text is not valid YAML at all. Usually a tab, an unquoted `#`, a stray `:` in an unquoted value, or a QR generator that mangled the payload. |
| *Not a ddIRC network config.* | Valid YAML, but not a mapping — an empty file, or a bare string, or a top-level list. |
| *No networks found in this file.* | There is no `networks:` key, or it is empty, or it is not a list. |
| *Every network in this file was missing something…* | `networks` had entries and **every one of them was rejected** — almost always a quoted or non-integer `port`, or a missing `host` / `nickname`. |
| Imports fine, then fails to connect | Wrong port for TLS (`6667` instead of `6697`), a host that does not resolve, or a proxy that is not running. **Test connection** on the import screen catches all three before saving. |
| Imports and connects, but is not logged in | A credential key was misspelled, or the network wants NickServ rather than SASL. |

---

## Checklist for a hand-written file

- [ ] Extension is `.irc`
- [ ] `networks:` is present and holds at least one `- ` entry
- [ ] Every entry has `host`, `port`, `nickname`
- [ ] `port` is a bare integer, and it is the **TLS** port
- [ ] Every `#` channel is quoted, and `channels` is a list
- [ ] Indented with spaces, never tabs
- [ ] Keys are camelCase and spelled as in the table
- [ ] Any password uses one of [the four names](#the-four-names)
- [ ] If it has passwords in it: you meant to write them there, and you know
      where the file is going to live afterwards
