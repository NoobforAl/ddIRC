/// The networks ddIRC ships knowing about, and the channels worth starting in.
///
/// A new install otherwise opens on an empty form asking for a hostname and a
/// port, which is a question only someone who already uses IRC can answer.
/// This is the answer, for the networks that are actually still there.
///
/// Two rules decided what is in the list. Every entry is reachable over TLS on
/// a published round-robin hostname, because the app does not make unencrypted
/// connections and an entry it cannot connect to is worse than no entry at
/// all — that is why QuakeNet and GameSurge, both alive and both large, are
/// absent. And every entry was checked against its own operators' current
/// connection documentation rather than remembered, because the interesting
/// half of this list is which networks outlived the ones beside them.
///
/// The channels are suggestions and are described as such in the UI. A channel
/// is a room full of people, not a fact about a server: it can empty out
/// between releases of this app, and nothing here can promise otherwise. What
/// the list does promise is that each one is a channel that network's own
/// documentation or community points newcomers at.
library;

import 'package:flutter/foundation.dart';

/// One channel worth suggesting, and why.
@immutable
class KnownChannel {
  const KnownChannel(this.name, this.blurb);

  /// Including the leading `#`, as it is typed and as it is joined.
  final String name;

  /// One line, lower case, no full stop — it sits under the name in a row.
  final String blurb;
}

/// A network ddIRC already knows how to reach.
@immutable
class KnownNetwork {
  const KnownNetwork({
    required this.name,
    required this.host,
    required this.blurb,
    this.port = 6697,
    this.sasl = false,
    this.note,
    this.channels = const [],
  });

  /// What the network calls itself, which becomes the profile name.
  final String name;

  final String host;

  /// TLS, always. Every network here publishes 6697; the field exists so one
  /// that moves does not need a new shape.
  final int port;

  /// A sentence for the network row.
  final String blurb;

  /// Whether SASL PLAIN is known to work here.
  ///
  /// Only set where the network's own documentation says so. False means "not
  /// established", not "impossible" — [note] carries the story when there is
  /// one worth telling, as on OFTC.
  final bool sasl;

  /// Anything the user should know before connecting: a network without
  /// services, a network whose TLS lives on one host rather than the
  /// round-robin. Null when there is nothing to say.
  final String? note;

  final List<KnownChannel> channels;

  /// Whether this network matches a search.
  ///
  /// Channels count: someone looking for `#debian` should find OFTC without
  /// having to know that is where Debian went.
  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    if (name.toLowerCase().contains(q)) return true;
    if (host.toLowerCase().contains(q)) return true;
    if (blurb.toLowerCase().contains(q)) return true;
    return channels.any(
      (c) =>
          c.name.toLowerCase().contains(q) || c.blurb.toLowerCase().contains(q),
    );
  }
}

/// The catalogue, roughly in order of how many people are on each network.
const knownNetworks = <KnownNetwork>[
  KnownNetwork(
    name: 'Libera.Chat',
    host: 'irc.libera.chat',
    blurb:
        'The largest network. Most free-software projects moved here in 2021 '
        'and stayed.',
    sasl: true,
    channels: [
      KnownChannel('#libera', 'network help, and the busiest room on it'),
      KnownChannel('#linux', 'general Linux talk'),
      KnownChannel('#python', 'the Python language'),
      KnownChannel('#rust', 'the Rust language'),
      KnownChannel('#git', 'using git, and getting out of git'),
      KnownChannel('#vim', 'vim and neovim'),
      KnownChannel('#emacs', 'emacs and its endless configuration'),
      KnownChannel('#archlinux', 'Arch Linux user support'),
      KnownChannel('#gentoo', 'Gentoo user support'),
      KnownChannel('#fedora', 'Fedora user support'),
      KnownChannel('#nixos', 'Nix and NixOS'),
      KnownChannel('#kernelnewbies', 'learning the Linux kernel'),
    ],
  ),
  KnownNetwork(
    name: 'OFTC',
    host: 'irc.oftc.net',
    blurb:
        'Open and Free Technology Community. Debian, Tor and much of the '
        'infrastructure world.',
    note:
        'OFTC identifies you with a client certificate (CertFP) rather than '
        'SASL, so leave the SASL fields empty here.',
    channels: [
      KnownChannel('#oftc', 'network help'),
      KnownChannel('#debian', 'Debian user support'),
      KnownChannel('#debian-devel', 'Debian development'),
      KnownChannel('#tor', 'using Tor'),
      KnownChannel('#tor-project', 'Tor development'),
      KnownChannel('#qemu', 'QEMU and emulation'),
      KnownChannel('#ceph', 'the Ceph storage system'),
      KnownChannel('#openstack', 'OpenStack, which moved here in 2021'),
    ],
  ),
  KnownNetwork(
    name: 'Undernet',
    host: 'irc.undernet.org',
    blurb:
        'Running since 1992, and still one of the three largest. Channels are '
        'held through the X service rather than ChanServ.',
    channels: [
      KnownChannel('#help', 'new-user help'),
      KnownChannel('#cservice', 'registering and recovering channels'),
    ],
  ),
  KnownNetwork(
    name: 'IRCnet',
    host: 'ssl.irc.atw-inter.net',
    blurb:
        'The 1996 split from EFnet, and still tens of thousands of people, '
        'mostly European.',
    note:
        'IRCnet has no network-wide TLS address. This is the open SSL server '
        'its own connection guide points at; the usual open.ircnet.net is '
        'plaintext only and so cannot be used here.',
    channels: [KnownChannel('#help', 'new-user help')],
  ),
  KnownNetwork(
    name: 'Rizon',
    host: 'irc.rizon.net',
    blurb: 'Anime, fansubbing and general chat. Large, and busy at all hours.',
    sasl: true,
    channels: [
      KnownChannel('#help', 'network help'),
      KnownChannel('#chat', 'the general room'),
      KnownChannel('#anime', 'anime talk'),
    ],
  ),
  KnownNetwork(
    name: 'EFnet',
    host: 'irc.efnet.org',
    blurb:
        'The original network, more or less unchanged since 1990. No central '
        'authority, by design.',
    note:
        'EFnet runs no services at all: nicknames and channels cannot be '
        'registered, and a channel belongs to whoever is holding it. Nothing '
        'is kept for you between visits.',
  ),
  KnownNetwork(
    name: 'DALnet',
    host: 'irc.dal.net',
    blurb:
        'Where NickServ and ChanServ were invented. Still around 10,000 '
        'people across a few thousand channels.',
    channels: [KnownChannel('#help', 'new-user help')],
  ),
  KnownNetwork(
    name: 'hackint',
    host: 'irc.hackint.org',
    blurb:
        'The hacker community\'s network — CCC, congresses, and the people '
        'who run their own infrastructure.',
    sasl: true,
    channels: [
      KnownChannel('#hackint', 'network help'),
      KnownChannel('#ccc', 'Chaos Computer Club'),
      KnownChannel('#dn42', 'the dn42 overlay network'),
    ],
  ),
  KnownNetwork(
    name: 'tilde.chat',
    host: 'irc.tilde.chat',
    blurb:
        'The shared network of the tilde communities: small public unix '
        'servers, run by hand.',
    channels: [
      KnownChannel('#meta', 'the main room'),
      KnownChannel('#helpdesk', 'getting an operator\'s attention'),
    ],
  ),
  KnownNetwork(
    name: 'Snoonet',
    host: 'irc.snoonet.org',
    blurb: 'Grew out of Reddit\'s communities and outlived most of them.',
    channels: [KnownChannel('#help', 'new-user help')],
  ),
];

/// The catalogue entry for a hostname, or null.
///
/// Matched on the host alone and case-insensitively, so a profile the user
/// typed by hand still gets the channel suggestions. The port is deliberately
/// not part of the match: someone on Libera's 7000 is still on Libera.
KnownNetwork? knownNetworkFor(String host) {
  final needle = host.trim().toLowerCase();
  if (needle.isEmpty) return null;
  for (final network in knownNetworks) {
    if (network.host.toLowerCase() == needle) return network;
  }
  return null;
}

/// The networks matching a search box, in catalogue order.
List<KnownNetwork> searchNetworks(String query) {
  final q = query.trim();
  return knownNetworks.where((n) => n.matches(q)).toList(growable: false);
}

/// A comma-separated channel field, as a list.
///
/// One definition, used by the editor's field, its suggestion chips and the
/// profile it builds — three readings of the same text that drifted apart
/// would show the user a chip that disagreed with the box above it.
List<String> parseChannels(String text) => text
    .split(',')
    .map((c) => c.trim())
    .where((c) => c.isNotEmpty)
    .toList(growable: false);

/// Add [name] to [channels], or take it out if it is already there.
///
/// Case-insensitive, because IRC is: someone who typed `#Debian` and then
/// tapped the `#debian` suggestion means one channel, not two, and joining
/// both would put the same room in the list twice. The rest of the list keeps
/// its order and its spelling — this only ever touches the one entry.
List<String> toggleChannel(List<String> channels, String name) {
  final next = [...channels];
  final index = next.indexWhere((c) => c.toLowerCase() == name.toLowerCase());
  if (index == -1) {
    next.add(name);
  } else {
    next.removeAt(index);
  }
  return next;
}
