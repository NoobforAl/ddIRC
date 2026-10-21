# The terminal client and server

`ddirc-cli` is two programs in one binary, both built on the same Rust core as
the app: an IRC **client** and an IRC **server**. Each has a full-screen
interface; each can be run as plain lines instead.

```bash
cargo run -p ddirc-cli -- client --server irc.libera.chat --nick yournick --channel '#test'
cargo run -p ddirc-cli -- server
```

Flags with no subcommand in front are the client's, as they were before the
split, so `ddirc-cli --server x --nick y` and every script that uses it still
work.

To try both without Docker, in two terminals:

```bash
make dev-tui-server              # the server manager, on 127.0.0.1:6698
make dev-tui                     # a client, joined to #ddirc-test on it
make dev-tui TUI_NICK=other      # a second person to talk to
```

`TUI_PORT`, `TUI_NICK` and `TUI_FLAGS` override the defaults, and `TUI_FLAGS=--no-tui`
gives the plain-lines client or the headless server. The server's certificate
authority is kept in `dev/tui/` (ignored by git — it holds a private key), and
`make dev-tui-clean` forgets it. Port 6698 rather than 6697 so it can run beside
`make dev-server`.

Full-screen is the default **when there is a terminal**. If the output is
redirected or the input is a pipe, both fall back to plain lines by themselves;
`--no-tui` asks for that explicitly.

## The client

```
ddirc-cli client --nick <NICK> [--server HOST] [--port PORT] [--channel #c ...]
                 [--sasl-account NAME] [--ca-file PATH] [--proxy HOST:PORT]
                 [--proxy-user NAME] [--no-tui] [--log-file PATH]
```

Secrets are read from the environment, never from argv — command lines are
visible to other processes and land in shell history:
`DDIRC_SASL_PASSWORD`, `DDIRC_NICKSERV_PASSWORD`, `DDIRC_SERVER_PASSWORD`,
`DDIRC_PROXY_PASSWORD`.

### An XMPP account

```
DDIRC_XMPP_PASSWORD=... ddirc-cli client --xmpp name@example.org
                 [--channel room@conference.example.org ...]
                 [--server HOST] [--port PORT] [--ca-file PATH]
                 [--proxy HOST:PORT] [--no-tui]
```

`--xmpp` takes the place of `--nick`, which is IRC's and is refused beside it, as
is `--sasl-account`. `--server` and `--port` are overrides here, for a host that
runs its server somewhere other than the address's own domain; without them the
server is worked out from the address and the port is 5223. `--channel` names a
room.

In the full-screen client, rooms and people are told apart by what has been
opened, since both are addresses: `/join room@conference.example.org` does not
add a `#`, and `/topic` and `/kick` act on a room but not on a conversation with
a person.

The text box at the bottom is a single soft bar rather than an outlined box:
the conversation it will send to on the left (`#rust ›`), a muted placeholder
while it is empty, and a `↵ send` hint on the right once there is something to
send. The rounded ends are half-block characters, so it needs no more of the
screen than the one row you type on.

The screen is a list of windows on the left (the server's, then one per channel
and private conversation), the conversation in the middle, and who is in the
channel on the right. Windows with something unread show a count; yellow means
it was addressed to you. The side panels are left out on a narrow terminal.

| Key | Does |
|---|---|
| Enter | send |
| Tab | complete a nick — again for the next one |
| ↑ / ↓ | lines you typed before |
| PgUp / PgDn | scroll back (the view holds still while new lines arrive) |
| Ctrl-N / Ctrl-P, Alt-← / Alt-→ | next / previous window |
| Alt-1 … Alt-9 | jump to a window |
| Esc | clear the line |
| F1 | help |
| Ctrl-C | quit |

Commands: `/join #channel [key]`, `/part [#channel] [reason]`,
`/msg <target> <text>`, `/query <nick>`, `/me <action>`, `/nick <new>`,
`/topic <text>`, `/kick <nick> [reason]`, `/whois <nick>`, `/list`, `/close`,
`/clear`, `/quit [reason]`. Anything else goes to the current conversation, and
an unknown `/command` is refused rather than sent — a typo like `/jion` is never
broadcast to a channel.

`/list` opens a browser over the server's channels, busiest first; Enter joins
the highlighted one. Being **kicked** closes the window and puts the reason —
who, and why — in the server window, where it can be read.

**Other keyboard layouts.** A terminal reports the character a key produced,
not which key it was, so on a Persian layout Ctrl-C arrives as Ctrl-ز and would
match nothing. Shortcuts therefore map a character back to the Latin key in the
same physical position (Persian, Arabic, Russian, Greek and Hebrew are covered).
It applies to chords, and to screens with nothing to type into; a plain key in
the input line is text, and stays in the language it was typed in. The server
manager's command line also opens with F2, for layouts that have no `:` where a
US keyboard does.

The core's own diagnostics have nowhere to go on a full screen, so they are
dropped unless you pass `--log-file`.

`--no-tui` is the original harness: one line per event on stdout, one line per
command on stdin. It is the Phase 1 acceptance gate for `ddirc-core` and it
stays useful for the same reason — it hides nothing.

## The server

```
ddirc-cli server [--port 6697] [--name ddirc.local] [--network Local]
                 [--motd LINE ...] [--data-dir PATH] [--no-tui]
```

It is the server that ships inside the app ([the local server](local-server.md)),
run on its own. That includes the part that matters most: **it listens on
loopback only**, over TLS, with a certificate it issues itself. Another machine
cannot reach it, and that is deliberate — see the reasoning in the local-server
document. To point a client at it, trust the certificate it prints at startup:

```
ddirc-cli client --server 127.0.0.1 --port 6697 \
    --ca-file "…/local-server-ca.pem" --nick you
```

The certificate authority lives in `--data-dir` (per-user, out of the way, by
default) and survives restarts, so a client that trusts it once keeps trusting
it. `--port 0` picks a free port.

Its private key is the one secret, so the directory is treated accordingly. If
there is no per-user place to put it (`LOCALAPPDATA`, `XDG_DATA_HOME` and `HOME`
all unset) the server stops and asks for `--data-dir` rather than falling back to
the shared temporary directory. On Unix a directory it creates is private to its
owner, and one that is a symbolic link, belongs to someone else, or can be
written to by group or others is refused, as is a key file that is a link or is
readable by others. Any of those would let someone else swap the certificate a
client trusts.

### The manager

Three tabs — **Users**, **Channels** and **Log** — under a header with the
address, uptime and counts, and an activity feed underneath every tab but the
log's own.

| Key | Does |
|---|---|
| 1 2 3 / Tab | switch tab |
| ↑ ↓ PgUp PgDn | move the selection |
| → / ← | (Channels) into the member list / back out |
| `k` | kick — opens the command line as `kick #chan nick ` for you to finish |
| `x` | disconnect from the server (asks first) |
| `b` | ban the nick: disconnect, and refuse the name (asks first) |
| `m` | send a notice to the selected person |
| `o` | (Channels, member list) give or take operator status |
| `t` `n` `c` | (Channels) topic · say in the channel · close it (asks first) |
| `w` | notice to everyone connected |
| `M` | edit the message of the day |
| `u` | unban |
| `:` | type a command |
| `?` / F1 | help |
| `q` | stop the server (asks first) · Ctrl-C stops it at once |

The same things as typed commands: `kick <#chan> <nick> [reason]`,
`kill <nick> [reason]`, `ban <nick> [reason]`, `unban <nick>`,
`topic <#chan> [text]`, `close <#chan> [reason]`, `op` / `deop <#chan> <nick>`,
`say <nick|#chan> <text>`, `wall <text>`, `motd [line | line …]`.

Two decisions worth knowing about:

* **A selection is a person, not a row.** The lists are live, so a row index
  would slide onto someone else between choosing a person and acting on them —
  and the actions are kick and ban. The selection is the thing itself, and a
  confirmation names whoever was chosen when it was asked.
* **Destructive actions ask, and only `y` agrees.** Enter does not, because Enter
  is what a hand does on its way to something else.

### Without the screen

`--no-tui`, or any non-terminal output, prints a log instead and takes no input:

```
12:52:31  connection #1 opened
12:52:31  alice registered (connection #1)
12:52:35  alice joined #lab
12:52:36  #lab <alice> hello from alice
```

One event per line, flushed as it happens, in UTC. Ctrl-C stops it. It reads
nothing from stdin on purpose: a daemon that reads its stdin is a daemon that
exits when the terminal it was started from closes.

**What clients typed cannot drive your terminal.** A message, a topic or a quit
reason can contain escape sequences, and a terminal acts on them — clearing the
screen, setting the title, even writing to the clipboard. Everything a client
chose is escaped to visible text (`\x1b]52;…`) before it is logged, so a message
that tried it shows that it did, rather than doing it. The full-screen
interfaces draw through a layer that drops control characters, and tests hold
that for both.

**Direct messages are logged as the fact, not the contents** —
`alice sent a private message to bob`. A channel is a room the operator is
hosting; a private message is between two people who did not address it to
whoever runs the server. Channel messages are logged in full.

## What it needs from the core

Two small things the server's operator controls depend on were missing from the
client, and are now there for the app as well as the CLI: a `KICK` is shown as
the departure it is (with who and why in the reason), and a `QUIT` is given a
moment to leave before the connection is dropped, so the reason someone typed is
the one the room reads.
