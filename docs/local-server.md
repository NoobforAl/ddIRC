# The local server

**Beta.** App settings → Connection → *Local server* has one switch: turn it on
and the server starts and a network appears in the rail, pointed at it. The port
changes each start and the network is kept pointed at it. What follows is what it
does and why it is shaped this way.

It is an IRC server that runs inside ddIRC, so there is somewhere to talk that
needs no daemon installed, no account made, and nobody's permission. A scratch
network, a place to develop against without Docker, and a target that is there
when nothing else is.

## Loopback only, on purpose

It binds `127.0.0.1` and `::1` and nothing else, and that is a decision rather
than a first step.

Reaching it from another machine would mean handing that machine's client a
trust anchor, because the certificate is issued locally and no public authority
will ever vouch for it. Handing someone a certificate to install is exactly the
control this codebase refuses to build — see [Dependency posture](architecture.md#dependency-posture) and the note
on `extra_root_cert` below. A local server is not a good enough reason to open
that door.

The duller half of the reason is just as real: a server other people can reach
needs a routable address, a way through NAT, and a free port. An app cannot
arrange those.

There is a real answer for *reachable from elsewhere*, and it is not a bigger
listener — publish it as an onion service, where the address is the key and NAT
stops mattering. That waits on shipping Tor, which is its own roadmap item.

## It issues its own certificate, and that is not a bypass

The client requires TLS on every connection and has no way to skip
verification, so a plaintext local server would be unreachable from the app it
lives inside. It speaks real TLS instead, with a certificate the client really
verifies.

That is safe here for a reason that does not generalise: **the app is both
ends**. It issues the certificate and is the only thing that will ever be shown
it. No certificate from outside the machine enters the trust store, the anchor
covers one loopback address the app itself chose, and the private key is
generated locally and never sent anywhere. `extra_root_cert` stays absent from
the Dart-visible type, so there is still no control anyone can be talked into
using.

The CA is persisted, because a trust anchor that changed every launch would be
one the app had to be told about again every launch. The leaf is minted in
memory at each start and written nowhere, so the key that actually terminates
connections lives exactly as long as the server does.

## What it speaks

Registration with `CAP` negotiation, `ISUPPORT`, a MOTD, `JOIN`/`PART`,
`PRIVMSG`/`NOTICE`, `NAMES`, `TOPIC`, `LIST`, `WHOIS`, `KICK`, nick changes,
`PING`/`PONG` and `QUIT`. Channels get an operator — whoever created them — so
the `PREFIX=(o)@` it advertises means something: only an operator may `KICK`.
A `QUIT` ends the link, as it does on every other server, rather than waiting
for the client to hang up.

**A client that vanishes is noticed.** The server used to only listen, and a socket
nobody closes looks exactly like a quiet one — so an app killed mid-session, or a
phone that left the network, held its connection and its nickname indefinitely,
and the person reconnecting a minute later was told that their own name was in
use. Now a registered connection that says nothing for 90 seconds is sent a
`PING`, and one that then says nothing for another 45 is dropped with `Ping
timeout`, its nick freed. *Any* line counts as being heard, not only the `PONG`.
Both intervals are `Config::ping_after` and `Config::ping_timeout`.

## The operator's controls

The protocol above answers *clients*. The person running the server has a
separate surface, `ddirc_server::admin`, and it is a separate surface for one
reason: nothing in it is reachable from the network. There is no wire command
for any of it, so a client cannot talk its way into being the operator.

* `LocalServer::handle()` gives a cloneable `ServerHandle`.
* `snapshot()` returns a **copy** of who is connected and what channels exist.
  A UI that held a reference would need a lock; one that holds a copy needs
  nothing.
* `execute(AdminCommand)` kicks, disconnects, bans (the *name* — every client is
  on loopback, so an address would ban everybody), sets topics, closes channels,
  gives and takes operator status, sends notices, and sets the MOTD. It returns a
  sentence either way: "kicked bob from #room" and "bob is not in #room" are the
  two outcomes the operator needs told apart.
* `subscribe()` is a broadcast of what happens. A subscriber that falls behind
  loses the oldest, which is the right failure for a log view and means a slow
  terminal can never slow the server.

Admin commands run on the same task as every client's messages, between two of
them, so none of it takes a lock and none of it can observe a half-applied
`JOIN`.

Two details are chosen, not incidental. **Direct-message bodies are not in the
event stream** — that one happened is reported, what was said is not, because a
private message is not the operator's to read. And **operator notices are sent
from a nick-shaped prefix** (`ddirc.local!server@localhost`), not from the bare
server name: a client treats a message with no nickname behind it as the
connection-time server chatter it discards, which is right for that and wrong
for words someone typed and wants read.

The terminal front end for all of this is described in [the CLI](cli.md).

Inside, one owner and no locks: a reader and a writer task per connection, and
a single task holding all the state. A server is almost entirely cross-client
work — a join touches everyone in the channel, a rename everyone who shares one
— and doing that under per-client locks is how deadlocks and half-applied state
get in. It also means the protocol is testable without a socket, which is most
of why the tests are quick.

**The MOTD says it is beta.** A MOTD is the one thing every client shows on
arrival, and whoever connected may not be whoever switched it on.
