/// XMPP servers that take new accounts, for someone who has an address to type
/// and no account to type it into.
///
/// XMPP has no equivalent of picking an IRC network: an account lives on one
/// server, and it is made on that server's own website. So this list is not a
/// directory of places to connect to but of places to sign up, and the app's
/// part is to open the sign-up page and, once there is an account, fill in
/// where it lives.
///
/// The same two rules as the IRC list in `directory.dart`, because they are the
/// same promise. Every entry is reachable over TLS from the first byte - the app
/// makes no other kind of connection - and an entry that cannot be connected to
/// is worse than none. And every entry was *checked*, not remembered: on
/// 2026-10-21 each was dialled at the host and port given here, the certificate
/// was verified against the domain with the ordinary trust store, the server
/// offered SCRAM logins, and its sign-up page was fetched and was open. Those
/// are the only facts claimed. Nothing here says a server is private, trustworthy
/// or going to be there next year, because nothing about dialling it can show
/// that; the app does not run or endorse any of them.
///
/// What was left out is as informative as what is in. `jabber.at` is large and
/// has a sign-up page that says registration is deactivated; `disroot.org`,
/// `snikket.chat` and several others did not answer on their TLS port from the
/// place this was checked; `creep.im` presented an expired certificate. A list
/// that included them would have sent people to a dead end.
///
/// Three, not thirty: each is one more thing that can be out of date, and the
/// address of any other server can still be typed by hand.
library;

import 'package:flutter/foundation.dart';

/// One server that takes sign-ups.
@immutable
class XmppProvider {
  const XmppProvider({
    required this.name,
    required this.domain,
    required this.signUpUrl,
    required this.blurb,
    this.host,
    this.port,
  });

  /// What it calls itself.
  final String name;

  /// The part after the `@` in an address there. The login is verified against
  /// this, whatever [host] is dialled.
  final String domain;

  /// Where to dial, when that is not [domain]. Many servers run on another
  /// machine than the one the domain names and say so in DNS; the app does not
  /// look that up itself (a lookup from this process would be one the proxy
  /// cannot hide), so it is written down here.
  final String? host;

  /// The port, when it is not the usual one. Some servers offer encryption from
  /// the first byte on 443 instead of 5223.
  final int? port;

  /// The page where an account is made. `https`, always: it is where a password
  /// is chosen.
  final String signUpUrl;

  /// One sentence for the row, and only facts a person can use.
  final String blurb;

  /// Whether the server needs anything filled in beyond the address.
  bool get needsServer => host != null || port != null;
}

/// The servers, in no ranking: the order they are in is alphabetical.
const xmppProviders = <XmppProvider>[
  XmppProvider(
    name: '5222.de',
    domain: '5222.de',
    host: 'xmpp.5222.de',
    signUpUrl: 'https://5222.de/register/',
    blurb: 'A German server. The sign-up page is in German.',
  ),
  XmppProvider(
    name: 'jabbers.one',
    domain: 'jabbers.one',
    signUpUrl: 'https://jabbers.one/register',
    blurb: 'Sign up on the website; accepts its terms and privacy policy.',
  ),
  XmppProvider(
    name: 'jix.im',
    domain: 'jix.im',
    host: 'xmpp.jix.im',
    port: 443,
    signUpUrl: 'https://jix.im/en/register/',
    blurb:
        'Encrypted connections are on port 443, which suits a network that '
        'blocks the usual ones.',
  ),
];

/// The providers whose name or domain contains [query], ignoring case. Empty
/// matches everything.
List<XmppProvider> searchXmppProviders(String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return xmppProviders;
  return [
    for (final p in xmppProviders)
      if (p.name.toLowerCase().contains(needle) ||
          p.domain.toLowerCase().contains(needle))
        p,
  ];
}
