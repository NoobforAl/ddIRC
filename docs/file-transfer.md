# File transfer

How a file gets from one person to another in ddIRC, and
whether that works between any two people in the world.

Written from the code at version 0.12.4. The reachability results below are
worked out from what the code does; they have not been measured across real
networks.

## The short answers

**Can anyone in the world send a file to anyone else?**

- **On XMPP: nearly always.** The file goes through the server, so neither
  person's network matters. The server has to offer uploads, and the file can be
  100 MB at most.
- **On IRC: usually not.** The receiver has to connect directly to the sender,
  which only works from anywhere if the sender's machine has a public IPv4
  address. Most home and mobile connections do not. A fresh install, which uses
  Tor, cannot send over IRC at all.

## How file transfer works

The two protocols share a paperclip button and a confirmation sheet, and nothing
else. They differ in where the bytes travel.

```
                   you press the paperclip
                             |
                             v
               +----------------------------+
               | strip image metadata       |
               | show what was removed, ask |
               | "Send this file?"          |
               +----------------------------+
                             |
              +--------------+--------------+
              |                             |
           on IRC                        on XMPP
              |                             |
              v                             v
     +-----------------+           +-----------------+
     | DCC             |           | HTTP Upload     |
     | direct TCP from |           | HTTPS to a      |
     | machine to      |           | server, then a  |
     | machine         |           | link is sent    |
     +-----------------+           +-----------------+
```

### IRC: DCC, a direct connection

The IRC server only carries the offer. The file itself travels over a separate
TCP connection between the two machines.

```
   SENDER                     IRC SERVER                  RECEIVER
     |                            |                           |
 (1) | Is a proxy or Tor on?      |                           |
     | Yes: refuse, nothing sent  |                           |
     |                            |                           |
 (2) | Listen on a random port    |                           |
     | Look up own local IPv4     |                           |
     |                            |                           |
 (3) | DCC SEND name addr port size                           |
     |--------------------------->|-------------------------->|
     |     (the address is visible to everyone who gets it)   |
     |                            |                           |
     |                            |              (4) file card appears;
     |                            |                  nothing happens until
     |                            |                  they press download
     |                            |                           |
 (5) |<------------------ receiver connects ------------------|
     |      to the address in the offer, directly or through  |
     |      its own proxy if it has one                       |
     |                            |                           |
 (6) |=================== the file travels ==================>|
     |      plain TCP, not encrypted, not via the IRC server  |
     |                            |                           |
```

What that means in practice:

- **The offer lasts 120 seconds.** If nobody connects in that time, the sender
  sees "nobody connected within 120 seconds".
- **One offer serves one connection.** The first to connect gets the file, and
  the code does not check who it is. Offered to a channel, one person gets it.
- **The bytes are not encrypted.** The chat connection uses TLS, but the DCC
  connection is plain TCP.
- **The limit is 4 GB**, checked against the bytes that actually arrive.
- **The *File transfers* switch must be on.** With it off, offers are not shown
  and there is no paperclip. It is off by default.

### Why IRC usually fails across the internet

The sender advertises the address its own machine uses to reach the IRC server.
Behind a home router or a mobile carrier, that is a private address, which means
nothing to anyone outside that network.

```
   SENDER'S HOME                                      RECEIVER, ELSEWHERE
 +---------------------------+
 |  laptop 192.168.1.20      |
 |  listening on port 51234  |
 |            |              |
 |         router            |      offer says:
 |     public 203.0.113.7 ---+----> "connect to 192.168.1.20:51234"
 +---------------------------+                  |
                                                v
                                     dials 192.168.1.20 on the
                                     RECEIVER'S own network
                                                |
                                                v
                                     no sender there: transfer fails
```

ddIRC has nothing that works around this: no UPnP or NAT-PMP, no STUN, no hole
punching and no relay.

**Forwarding a port on your router does not help either.** The port is random on
every send, the advertised address is still the private one, and there is no
setting to change either of them.

**The receiver cannot rescue it.** The usual fix is a reverse offer, where the
receiver listens instead. ddIRC never sends one, and refuses them when they
arrive, with or without a proxy.

### Will my IRC transfer work?

Everything depends on the sender:

```
                     Is the sender using Tor or a proxy?
                        |                       |
                       yes                      no
                        |                       |
                        v                       v
                 REFUSED, nothing     Does the sender have an IPv4
                 is sent              address on this machine?
                                        |                  |
                                        no                yes
                                        |                  |
                                        v                  v
                                  REFUSED: "could   Is that address public,
                                  not work out      with inbound connections
                                  which address"    allowed?
                                                     |              |
                                                    yes             no
                                                     |              |
                                                     v              v
                                               WORKS FROM     WORKS ONLY for
                                               ANYWHERE       people who can
                                                              reach that address
                                                              (same LAN or VPN)
```

| Sender is on | Advertised address | Who can collect the file |
|---|---|---|
| Tor (fresh install) or a proxy | none, sending is refused | Nobody |
| Home Wi-Fi behind a router | Private, such as `192.168.x.x` | Same local network only |
| Mobile data behind carrier NAT | Private or shared | Usually nobody |
| A VPN | Usually the tunnel address | Others who can route to it |
| A server with a public IPv4 address | Public | Anyone, if the firewall allows it |
| An IPv6-only network | none, sending is refused | Nobody |

A receiver has more freedom. Behind a router it can still dial out, and on Tor
it dials through Tor, so the sender sees the Tor exit and not the receiver. A Tor
exit may refuse the port, since that depends on the exit's policy.

Another client at the sending end, such as one set up with its own public address
and a forwarded port, can send to ddIRC. The limit is in what ddIRC advertises,
and only applies when ddIRC is the sender.

### XMPP: HTTP Upload, through the server

Neither person connects to the other. The server stores the file and the message
carries a link to it.

```
   SENDER                     XMPP SERVER                  RECEIVER
     |                            |                           |
 (1) | May I upload this file?    |                           |
     |--------------------------->|                           |
     |                            |                           |
 (2) | Use this PUT and GET slot  |                           |
     |<---------------------------|                           |
     |                            |                           |
 (3) | Check the slot: https, no  |                           |
     | password, and not an       |                           |
     | address on a private net   |                           |
     |                            |                           |
 (4) | HTTPS PUT, via Tor or      |                           |
     | proxy if one is on         |                           |
     |===========================>|  server keeps the file    |
     |                            |                           |
 (5) | Message with the GET link  |                           |
     |--------------------------->|-------------------------->|
     |                            |                           |
     |                            |   (6) shown as a link;    |
     |                            |   nothing is fetched      |
     |                            |   until they open it      |
     |                            |<==========================|
     |                            |      HTTPS GET            |
```

- **It works from behind a router, on mobile data and over Tor**, because both
  people only ever connect outward.
- **The limit is 100 MB**, or less if the server sets a lower one.
- **The server must offer uploads.** Without that there is no paperclip. The
  *File transfers* switch does not control this; it is for IRC only.
- **Anyone with the link can download the file**, and the server keeps it. It is
  encrypted in transit, not end to end.
- **The receiver needs no special client.** The link is a normal HTTPS address.

### Side by side

| | IRC (DCC) | XMPP (HTTP Upload) |
|---|---|---|
| Path of the bytes | Sender's machine to receiver's | Through the server |
| Works between any two people | Only with a publicly reachable sender | Yes, if the server offers uploads |
| Sending on a fresh install (Tor) | Refused | Works |
| Who learns your address | The receiver, and everyone in a channel you offer to | Your server, unless Tor or a proxy is on |
| Who can get the file | The first to connect within 120 seconds | Anyone with the link, while the server keeps it |
| Encrypted in transit | No | Yes (HTTPS) |
| Size limit | 4 GB | 100 MB, or the server's lower limit |
| Interrupted download | Can resume if the sender offers it again | Not handled by ddIRC on the receiving side |
| Switch needed | *File transfers*, off by default | None |
| Terminal client (`/file`) | Not available | Available |

### Where an IRC offer may point

The address in an offer is the sender's choice, and accepting means connecting to
it, so it is checked first. Private addresses stay allowed with no proxy, because
that is what a sender on your own network looks like. The card names the address
before you press download, since the same number could also be your router.

```
           offer names an address, you press download
                             |
                             v
                     Is it public? --- yes ---> DIALLED
                             |
                             no
                             |
                             v
                   Are you using a proxy? --- yes ---> REFUSED
                             |
                             no
                             |
              +--------------+----------------+
              |              |                |
       private network  this machine    anything else
              |              |                |
              v              v                v
          DIALLED      Is your IRC         REFUSED
        (card named    server here too?
         the address)   |          |
                       yes         no
                        |          |
                        v          v
                     DIALLED    REFUSED
```

A refused offer sends nothing to the sender, not even a resume request.

## Where to look in the code

| Topic | File |
|---|---|
| Reading an offer, and classifying its address | `core/ddirc-core/src/dcc/offer.rs` |
| Moving the bytes, timeouts, limits and `check_destination` | `core/ddirc-core/src/dcc/transfer.rs` |
| Making an offer | `send_file` path in `core/ddirc-core/src/conn/actor.rs` |
| XMPP upload and slot checks | `core/ddirc-core/src/xmpp/upload.rs` |
| The sheet shown before sending | `lib/src/ui/send_file_sheet.dart` |
| The warning before turning transfers on | `lib/src/ui/settings/file_transfer_section.dart` |
