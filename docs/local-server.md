# The local server

**Beta, and not reachable from the app yet** — the crate is built and tested,
but it has no FFI and no settings switch. What follows is what it does and why
it is shaped this way.

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
`PRIVMSG`/`NOTICE`, `NAMES`, `TOPIC`, nick changes, `PING`/`PONG` and `QUIT`.
Channels get an operator — whoever created them — so the `PREFIX=(o)@` it
advertises means something.

Inside, one owner and no locks: a reader and a writer task per connection, and
a single task holding all the state. A server is almost entirely cross-client
work — a join touches everyone in the channel, a rename everyone who shares one
— and doing that under per-client locks is how deadlocks and half-applied state
get in. It also means the protocol is testable without a socket, which is most
of why the tests are quick.

**The MOTD says it is beta.** A MOTD is the one thing every client shows on
arrival, and whoever connected may not be whoever switched it on.
