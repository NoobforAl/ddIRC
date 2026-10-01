# Features

What the app does, and why each piece works the way it does.

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

**Reconnection distinguishes two things that look alike.** A connection that
*was* working and dropped — a tunnel, a handoff between Wi-Fi and cellular, a
server bouncing — comes back on its own, with exponential backoff and jitter.
A connection that has **never** registered gets three attempts, then stops,
says why, and waits to be asked. A wrong address or a blocked port is not
something persistence fixes, and retrying it every five minutes produces a
countdown that never ends while the actual reason sits unread.

**The account of the connection is not in the conversation.** Attempts, TLS,
registration and whatever the server objected to go to a per-connection log,
reached from **View log** on the status bar under the header, or from
*Connection log…* in the header menu once the bar has gone. They used to be
filed as muted grey lines into whichever channel happened to be on screen when
they arrived, which made a channel's history part conversation and part
plumbing — and scattered one connection's story across every room visited while
it was failing. The log is in memory only, bounded at 300 lines, and copyable in
one press for a bug report. Nothing reaches disk unless the debug log is on.

**A network can be tried before it is saved.** *Test connection* in the network
editor runs the whole journey once — the proxy, TLS, capability negotiation,
SASL, registration — and reports what happened next to the fields that caused
it, rather than leaving a wrong port to surface as a session stuck at
"Reconnecting". It joins nothing, sends no NickServ password, and quits as soon
as the server says hello.

### Talking to one person

Tap a nick in the member list, or type `/query <nick>`, and a conversation with
them opens having sent nothing. `/msg <nick> <text>` still works and still opens
one; the difference is that deciding to talk to someone and deciding what to say
are two acts, and the first should not require the second.

**A first message from a stranger is a request, not a conversation.** On IRC
anyone can message anyone, so an inbox that opens itself on demand is a thing
other people control. Someone you have never spoken to does not get a tab, does
not take the screen, and cannot be replied to until you say so — the composer is
replaced by *Accept* and *Decline*, because sending anything at all, even a
refusal, confirms that somebody is here.

**Declining blocks them on that network.** Their later messages are dropped
before they reach a conversation, an unread count or a log, and you are not
asked again — a refusal you have to repeat every time is not a refusal. The
block is per network and folded to lower case, since IRC nicks are
case-insensitive and one that `Alice` could step around by capitalising would be
no block at all. **Blocked** in the network's settings is where it is undone.

### Browse networks

A new install has nothing saved, and the form it used to open on asked for a
hostname and a port — a question only somebody who already uses IRC can
answer. **Browse networks**, in the rail and on the empty screen, answers it:
ten networks that are still running, each with the channels worth starting in.
Search matches names, addresses and channels, so typing `debian` finds OFTC
without the user having to know that is where Debian went.

The list is in `lib/src/model/directory.dart`. Two rules decided what is on
it. Every entry is reachable over **TLS on a published round-robin hostname**,
because the app makes no unencrypted connections and an entry it cannot
connect to is worse than no entry — that is why QuakeNet and GameSurge, both
alive and both large, are absent. And every entry was checked against its own
operators' current connection documentation, because the interesting half of
this list is which networks outlived the ones beside them.

Where connecting without knowing something would waste an afternoon, the entry
says so, in the picker and again in the editor: EFnet runs no services at all,
OFTC takes a client certificate rather than a SASL password, and IRCnet's TLS
is not on the address every guide gives you.

Picking a network does not save or connect anything. It fills in the profile
editor, which is still where a network is created — the nickname is asked for
and the proxy is reviewed exactly as they are for a server typed in by hand.
The suggested channels also appear as toggles under the **Channels** field
whenever the address matches a known network, typed or picked, and they write
into that field rather than into a selection of their own, so there is never a
tick that disagrees with the text beside it.

Profiles are stored in `shared_preferences`; **SASL passwords are not**. Those
go to the platform keychain via `flutter_secure_storage` — Android Keystore,
DPAPI on Windows — are read only at connect time, and are zeroized by the core
once authentication completes.

### The `.irc` file, and scanning one in

A saved network can leave the device it was created on. **Export**, in the
network editor's header, writes the profile as `.irc` — plain YAML, with an
extension of its own rather than borrowed `.yaml`, so a file manager or a chat
attachment says what it is before anyone opens it (the full format is in
[irc-file-format.md](irc-file-format.md)):

```yaml
ddirc: 1
networks:
  - name: 'Libera'
    host: 'irc.libera.chat'
    port: 6697
    nickname: 'ddirc'
    channels: ['#ddirc']
```

One file can name more than one network, and every field in it is exactly
what `Profile.toJson` already writes to `shared_preferences` — which is the
whole reason this did not need a second schema to keep in step with the
first. That also answers the question worth asking before sharing one:
**no password is ever in it.** Every credential a profile can carry —
SASL, the server password, NickServ, a proxy's own — lives in the platform
keychain and never reaches `Profile.toJson` in the first place, so a `.irc`
file is secret-free by construction rather than by a filter applied on the
way out. See [SECURITY.md](../SECURITY.md).

**Import** reads the same format back, from a file or from a **QR code**
carrying the same YAML as its payload — `lib/src/model/ircconfig.dart` is the
one parser both go through, so a file and a scan are the same thing the
moment there is text to read. Scanning uses
[`mobile_scanner`](https://pub.dev/packages/mobile_scanner), the only new
dependency any of this needed; it owns the Android camera permission itself,
unlike the notification and background-service permissions this app asks for
by hand over its own channel — see *Being told that something was said*,
below. Either source lands on the same review screen, one row per network
found and a checkbox on each, before anything is saved — the same way
picking a network from Browse fills in the editor rather than connecting on
the spot.

**Add a network**, beside Browse, opens a menu rather than a form directly:
*by hand*, *by QR code*, or *by `.irc` file*. These three used to be three
buttons standing side by side — the rail was five icons deep before Browse
and App settings even got a look, and the empty screen carried a button for
each — and folding them behind one is what kept the rail a rail rather than a
list.

## Chat

IRC has no server-side anything for the conveniences a modern messenger has
taught people to expect — there is nowhere to keep a draft, a pin or a read
position but the client. So the client keeps them.

### What needs message history, and what does not

Some of these exist to be there *later*: a pinned message, a saved one, a
conversation pinned to the top of the list. Without somewhere to keep them
they would work for an afternoon and be gone on the next launch, which is a
promise the app would be breaking quietly. So they are offered only while
**Save messages to a database** (Privacy) is on, and where they would appear
with it off, the control is there, greyed, saying so.

| Works always | Needs message history |
|---|---|
| Drafts, while the app is open | Drafts that survive a restart |
| Markdown, and tappable links | Pinned messages, and the pinned bar |
| The message menu: reply, quote, copy, mention | Saved messages |
| The @ button for unread mentions | Pinning and archiving conversations |
| Search in what the scrollback holds | Search further back, and scrolling up past it |
| Mute for a while; hiding a nick in channels | Unread counts and the "new messages" rule after a restart |
| The profile sheet, with WHOIS | |

All of it lives in the same database as the history, behind the same switch —
see [privacy.md](privacy.md). **Delete saved messages** takes drafts, pins,
saved messages and read positions with it; what you wrote about people stays,
because that is not a message.

### Drafts

Whatever is typed into the composer belongs to the conversation it was typed
in. Switching away puts it away, reply and all; switching back brings it
out. A conversation with a draft says so in the list, under its name — except
the one on screen, whose draft is already in front of you.

### Reading

The **New messages** rule and the unread badge used to be forgotten by
closing the app: history put yesterday back, and called none of it new. Now
the last line you saw is remembered, so a restart opens where you stopped
reading and counts what came after.

Above the way down sits an **@** button while there are mentions you have not
seen. Each press goes to the next, oldest first.

Scrolling to the top of a conversation loads the page above it from history,
a couple of hundred lines at a time, holding the line you were reading still.

### The message menu

Hold a message — or right-click it — for **Reply**, **Copy**, **Mention**,
**Pin** and **Save**. With part of the message selected, **Reply with quote**
answers just that part, and **Copy** copies just that part.

**Pinned messages** show in a bar at the top of the conversation. Tapping it
goes to the pin and moves on to the one before; the list button shows them
all. **Saved messages**, in the header menu, is your own list across every
network, most recent first; each is a copy, so it outlasts the conversation
it came from scrolling out of history.

### Markdown and links

`**bold**`, `*italic*` or `_italic_`, `~~struck~~` and `` `code` `` are sent
as IRC formatting — real bold, which every IRC client shows, rather than
asterisks only ddIRC would understand. The same marks typed by someone on
another client are drawn the way they meant them, and a line beginning `> `
is drawn as a quote. Nothing inside a code span or an address is touched, an
underscore inside a word is just an underscore, and `2 * 3 * 4` is arithmetic.
**Markdown** in Appearance turns all of it off.

Links in messages can be tapped. Before anything opens, the whole address is
shown — the part cut off at the edge of a bubble is exactly where a lookalike
domain hides — and only `http` and `https` are opened at all.

### Search

**Ctrl+F**, or **Search in conversation** in the header menu, puts a search
bar where the topic was. The arrows (or Enter and Shift+Enter) step through
matches in the scrollback, each highlighted where it falls. With history on,
older matches — from the full-text index in the store, so this does not read
the whole file — are listed underneath; picking one loads the scrollback back
to it.

### People

Tap a name for who they are: what the server says (`WHOIS` — asked when the
sheet opens and not before, since the other side's server sees it), the
channels you share, and what you wrote about them. From there: message them,
edit their name and note, **hide them in channels** — their lines stop
appearing in rooms you share, they can still message you, and nothing tells
them — or block their direct messages.

### The conversation list

Hold or right-click a conversation to **pin** it to the top, **archive** it
into a folded group at the bottom, **mute** it — for an hour, eight, a day, a
week, or until you say — or mark it read without opening it. An archived
conversation is still joined and still collecting messages; somebody saying
your name in it brings it back.

### The store underneath

Schema 5 of the history database adds what these need, and the things it
needed to scale:

- **A second, read-only connection.** WAL lets a reader see the last commit
  while a write is under way, but only if they are different connections;
  with one, restoring a conversation or answering a search queued behind
  whatever batch of messages was landing.
- **A full-text index** (FTS5, contentless) over what people said, with mIRC
  formatting stripped, kept in step with deletions by a trigger. What you
  type is never handed to it as query syntax.
- **Keyset paging** on (time, id), so loading the page above a line neither
  repeats nor skips one that shares its millisecond.
- **A unique server id per conversation**, so a bouncer replaying the last
  hour stores nothing twice.
- **Row ids returned to the app**, which is what a read position or a pin
  holds on to when the server sent no id of its own.
- Deleting a network now deletes its history too. It used to leave every
  line in the file, unreachable from the app and still on disk.

The full design is in `irc-core/ddirc-core/src/store/mod.rs`.

## Window

On desktop the app draws its own title bar: traffic-light close, minimise and
maximise on the left, their glyphs appearing on hover. The native caption is
hidden before the first frame, so it never flashes. Mobile is unaffected.

### Closing it, and not closing it

**Keep running when the window is closed** is off by default. Turned on, the
close button hides the window instead of quitting: the connections are held by
the Rust core on its own threads inside this process, so a hidden window is
still a connected one and nothing has to be re-established when it comes back.

The tray icon is not an extra. A window that hides leaving nothing on screen is
a lost app rather than a backgrounded one, so the icon goes up with the setting
and comes down with it — there is no arrangement in which the window can hide
with no icon to bring it back. Left-click restores; right-click offers *Show*
and *Quit*. Its tooltip says how many networks are connected, and says "not
connected" as plainly as it says a number.

Closing is always intercepted, whichever way the setting is set. That is what
lets a plain close send a `QUIT` first, so everyone in the channel sees you
leave now rather than time out two minutes later.

### The same promise on Android

The switch is there too, worded for the platform: *Stay connected in the
background*, and the app keeps its connections while you are in another app.

What it does underneath is not the same thing at all. Nothing on Android holds
a connection either — the Rust core does, as everywhere else — but the process
is not ours to keep. An app you are not looking at is a cached process, and a
cached process is the first thing killed when memory runs short. So on Android
the thing that has to be arranged is not a window that refuses to close but
permission to go on existing, which is what a foreground service is, and the
price Android charges for it is a notification.

That price is worth paying openly. An app holding a socket open while you are
not looking at it *should* be visible, and the notification does the same job
the tray icon does on desktop: it says the app is running, it says how many
networks are connected, and it carries the same Quit.

**Swiping the app away from Recents leaves it running**, and the switch says
so. That gesture dismisses the window; it is not a decision about the
connections, and treating it as one is what used to make the promise stop being
true the moment somebody tidied their Recents. *Quit* on the notification is the
way out, and it is on the notification so that there is always one.

Surviving it costs more than a flag, because the connections were never the
part at risk. They are in the Rust core and never cared about the window — but
the events they raise are read in Dart, the decision to notify is made in Dart,
and the notification is posted back over the channel from Dart. An engine that
died with the activity would leave the sockets open with nobody listening. So
the Flutter engine is made by `AppEngine.kt`, kept for the activity to attach
to, and outlives any number of windows; `MainActivity` is left being a window
and nothing else, and decides on the way out whether anything is behind it — if
the service is up the engine stays, and if it is not, it goes.

The service is `START_STICKY`, so Android putting the process back after taking
it for memory is a case rather than an ending: the notification goes up first,
because that is what buys the right to be running and Android is timing it, and
Dart follows and reconnects whatever was set to connect at launch. A service
stopped on purpose is never restarted, which is what makes *Quit* mean quit.

The service is declared `specialUse` rather than `dataSync`, which is the type
that looks like the obvious fit. From Android 15 a `dataSync` service is cut
off after six hours in any twenty-four — for a client whose whole purpose is to
still be connected this evening, that is not a limit but a silent failure.
`AndroidManifest.xml` carries the justification Google Play asks for at review.

No new dependency for any of this: the notification and the permission are
plain framework APIs behind version guards, and the channel between Dart and
`AppEngine.kt` carries a handful of methods.

### Being told that something was said

Staying connected is only half of it. The other half is finding out, which is a
separate feature with a separate switch, on by default.

**What it will interrupt you for: a direct message, or your nickname in a
channel.** Never ordinary channel traffic — every line of every room is what
makes people turn notifications off altogether, and one nobody has turned off
is worth more than one that says everything. A conversation set to *Muted* or
*Mentions only* in its own settings is quieter still; that setting can narrow
this, never widen it.

**What it says: who, and where.** *"ada — Libera.Chat"*, *"sent you a
message"*. The text of the message is behind a second switch that is **off**,
because a notification is drawn by the operating system and may sit on a lock
screen — which puts what was said somewhere this app can no longer take back.
A message from someone you have not accepted yet never shows its text at all,
whatever that switch says.

Nothing is raised for a conversation that is already on screen in a window that
is already in front, and opening a conversation takes away any notification
still asking about it.

Desktop uses [`local_notifier`](https://pub.dev/packages/local_notifier), from
the same family as the window and tray packages already here, so Windows, macOS
and Linux are one dependency rather than three. Android needs no dependency at
all: the app already owned a channel and a notification permission, so a
message notification is a second `NotificationChannel` — separate from the
service's, and at a higher importance, so silencing the price of staying
connected does not silence the point of it.

### iOS gets nothing, deliberately

The switch is absent there — not disabled. iOS will not hold a TCP socket open
for an app that is not in front, so the switch would be a promise the platform
refuses to keep, and a control that cannot keep its promise is worse than no
control.

## Settings

Three dialogs, reachable from the ⚙/⚌ controls in the header, and from a
right-click or long-press on any channel in the list.

They are a dialog on a screen with room for one and the **whole screen on a
phone**, and that is one shell knowing two shapes rather than two
presentations. Nine surfaces are built on it, and on a 411dp handset the
floating version was a 371-wide card inset 32 from the top and bottom — giving
up about a seventh of the screen to say "this is floating above something"
while covering that something almost entirely. Where it goes full bleed, the
system back gesture means *up one level* rather than *close*, because there it
is the only way back; on a desktop the same gesture is Escape and a click on
the barrier, both of which mean "I am finished" with the back arrow sitting on
screen for the other question.

| Dialog | What it holds |
|---|---|
| **App** | An index and four pages — *Appearance*, *Connection*, *Notifications*, *Privacy* — each row carrying what is currently set inside it, so "am I going through Tor" is answered without opening anything. One level of nesting and no more: a page opens in place, so there is never a dialog over a dialog. Applies to every server; persists. |
| **Channel** | Topic (editable), notification level — all / mentions only / muted, member counts, and leaving the channel. The level persists per channel. |
| **Server** | Nickname (changeable), and the connection as it actually is: status, host and port, network, transport, route (direct or through which proxy), authentication mechanism. Plus disconnect. |
| **Network** | The saved profile itself — name, address, port, channels, nickname, SASL account, whether to connect at launch, and this network's proxy. Every field explains itself behind a '?', and *Test connection* dials the server before anything is saved. Reached from the rail's context menu or the header menu. |

Preferences live in `shared_preferences`. **No credential is ever written
there** — see [SECURITY.md](../SECURITY.md).

Invalid input is reported on the field itself: the field turns red, states the
problem underneath, and shakes. Nothing is reported in a banner somewhere else
on the screen, and the layout never reflows.

## Sending and receiving files

IRC does not carry files through the server; two clients open a connection
between themselves and send over that. ddIRC does the same, which is what lets a
transfer work with someone who is not using it.

It is off by default — **Settings → Connection → File transfers**. With it off
no offer is even shown and there is no attach button.

**Sending.** The paperclip beside the composer. Picking a file runs it through
the metadata stripper first, so the confirmation can say what was actually taken
out of *this* file rather than what the setting promises in general, and then
asks. That dialog cannot be turned off, because one of the three things on it
never stops being true:

> The offer carries your address. Whoever accepts it connects to this machine,
> so they learn it — and offered to a channel, everyone in it does.

**Receiving.** An offer appears as a row with **Accept** and **Decline**.
Declining is silent: nothing is sent back, so a stranger fishing for a live
client learns nothing from being refused. Accepting saves into ddIRC's own
directory beside the logs, deliberately **not** the system Downloads folder — a
file somebody else chose does not belong among the ones you fetched yourself,
and on Android shared storage is readable by anything holding the permission.

Nothing overwrites. A name already taken is an error, and the file is written
under a `.part` name and renamed only once it is whole, so a transfer that dies
halfway cannot be mistaken for the file it was going to be. The size in an offer
is the sender's claim and is labelled as one; the 4 GB ceiling is enforced
against the bytes that actually arrive.

**With a proxy configured**, the rule is that a transfer discloses no more than
the connection that negotiated it:

| | No proxy | Proxy configured |
|---|---|---|
| **Accepting** a normal offer | dial them directly | dial them **through the proxy** |
| **Accepting** a reverse offer | listen, and tell them where | **refused** — listening means disclosing where you are |
| **Sending** | listen, and offer your address | **refused** — see below |

Sending from behind a proxy wants a reverse offer of our own, where they listen
and we dial out, and that half is not built. It is refused rather than falling
back to a direct offer, because a fallback is exactly the thing the rule exists
to prevent.

## Agents (MCP)

**Beta, and off.** App settings → Connection → *Agents (MCP)* runs a
[Model Context Protocol](https://modelcontextprotocol.io) server inside the
app, so an AI agent — Claude Code, Claude Desktop, any MCP client — can catch
up on your conversations and draft replies.

What an agent can do:

| Tool | What it does |
|---|---|
| `list_networks` | The networks connected right now, with your nick on each. |
| `list_conversations` | The channels and DMs open on one network, with unread counts and topics. |
| `read_messages` | Recent messages in one conversation, oldest first, each with an id; `before` pages back. |
| `search_messages` | Text search over what the app holds in memory, newest first. |
| `send_message` | Send to a conversation that is already open, optionally as a reply. |

**Nothing is sent without you.** Every `send_message` raises a sheet in the
app with the network, the conversation and the exact text, and waits — up to
two minutes — for *Send*, *Always allow in #channel*, or *Don't send*. There is
no tool to join, leave, change nick or run a command, because a message is the
only action whose whole effect can be read off a sheet before it happens. Text
from an agent is always sent as text: a line that starts with `/` is a line
that starts with `/`.

How it is reached: the Streamable HTTP transport, answered with plain JSON, at
`http://127.0.0.1:<port>/mcp` behind a random bearer token. The settings
section shows the address and the token, and copies a ready-made command:

```bash
claude mcp add --transport http ddirc http://127.0.0.1:PORT/mcp \
  --header "Authorization: Bearer TOKEN"
```

The port is kept between runs so a configured agent keeps working. *New token*
cuts off every agent holding the old one. While the app is locked the server
answers nothing. See [SECURITY.md](../SECURITY.md#agent-server-mcp).
