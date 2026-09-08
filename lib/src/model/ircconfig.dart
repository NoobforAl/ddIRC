import 'package:yaml/yaml.dart';

import 'profile.dart';
import 'proxy.dart';

/// The `.irc` file — one or more saved networks, in a format meant to leave
/// the device it was written on.
///
/// YAML rather than the JSON [ProfileStore] already writes to disk: the store
/// is read by nobody but this app, while a `.irc` file is read by a person
/// deciding whether to trust what is in it, and a person reads YAML. The
/// extension is its own thing rather than borrowing `.yaml` so that a file
/// manager, a chat attachment or a QR payload says what it is before anyone
/// opens it.
///
/// A list even when it holds one network: a QR code and a file share this one
/// parser, and a QR that could only ever encode a single network would have
/// become a second format the first time somebody asked to share two at once.
///
/// What is never in here: a password. [Profile.toJson] already stops at the
/// door of the keychain — SASL, the server password, NickServ, a proxy's own
/// credential all live in `flutter_secure_storage` and never reach the JSON
/// [ProfileStore] writes, which is the same shape this format writes to YAML
/// instead. Handing this file to someone hands them where to connect, never
/// what to authenticate with.
const _kVersion = 1;

/// Turn a `.irc` file's text — or whatever a scanned QR code decoded to —
/// into networks ready to review and save.
///
/// Tolerant the way [Profile.fromJson] is tolerant: one malformed network
/// entry is dropped rather than failing the whole import, because a file
/// somebody shared with five networks in it should not be refused over one
/// bad line. Throws [FormatException] only when there is nothing to salvage
/// at all — the text is not YAML, or names no networks.
///
/// Each network gets a fresh [ProfileStore.newId] rather than keeping
/// whatever id the exporting device wrote: that id is local housekeeping —
/// it keys a keychain entry on the device that saved it — and carrying one
/// over would risk two unrelated networks, saved on two different phones,
/// ending up addressed by the same key on a third.
List<Profile> parseIrcConfig(String source) {
  final Object? doc;
  try {
    doc = loadYaml(source);
  } on YamlException catch (e) {
    throw FormatException('Not a valid ddIRC network config: ${e.message}');
  }
  if (doc is! YamlMap) {
    throw const FormatException('Not a ddIRC network config.');
  }

  final networks = doc['networks'];
  if (networks is! YamlList || networks.isEmpty) {
    throw const FormatException('No networks found in this file.');
  }

  return [
    for (final entry in networks)
      if (entry is YamlMap)
        Profile.fromJson({
          ..._plain(entry) as Map<String, Object?>,
          'id': ProfileStore.newId(),
        }),
  ].whereType<Profile>().toList(growable: false);
}

/// Write one or more profiles as a `.irc` file.
///
/// Hand-rolled rather than built on a YAML-writing package: the schema is
/// small, flat, and owned entirely by this file, so a dependency able to
/// serialise arbitrary Dart objects would carry far more than this ever
/// calls on. Every string is single-quoted unconditionally rather than
/// selectively escaped — a channel name starting with `#` is a YAML comment
/// the moment it is not — which costs a couple of characters and buys not
/// having to enumerate every character that would otherwise need it.
String writeIrcConfig(List<Profile> profiles) {
  final buffer = StringBuffer('ddirc: $_kVersion\nnetworks:\n');
  for (final profile in profiles) {
    buffer.write(_network(profile));
  }
  return buffer.toString();
}

/// Every key here is exactly the key [Profile.toJson] uses, so a network
/// written by this file reads back through the same [Profile.fromJson] the
/// on-disk profile store already trusts — one reader for both, rather than a
/// second field-mapping this format would have to keep in step with the
/// first.
String _network(Profile profile) {
  final lines = <String>[
    '  - name: ${_scalar(profile.name)}',
    '    host: ${_scalar(profile.host)}',
    '    port: ${profile.port}',
    '    nickname: ${_scalar(profile.nickname)}',
  ];
  if (profile.altNicks.isNotEmpty) {
    lines.add('    altNicks: ${_list(profile.altNicks)}');
  }
  if (profile.channels.isNotEmpty) {
    lines.add('    channels: ${_list(profile.channels)}');
  }
  final account = profile.saslAccount;
  if (account != null && account.isNotEmpty) {
    lines.add('    saslAccount: ${_scalar(account)}');
  }
  if (profile.proxyMode != ProxyMode.followDefault) {
    lines.add('    proxyMode: ${_scalar(profile.proxyMode.name)}');
    final proxy = profile.proxy;
    if (profile.proxyMode == ProxyMode.custom && proxy != null) {
      lines.add('    proxy:');
      lines.add('      host: ${_scalar(proxy.host)}');
      lines.add('      port: ${proxy.port}');
      final username = proxy.username;
      if (username != null && username.isNotEmpty) {
        lines.add('      username: ${_scalar(username)}');
      }
    }
  }
  if (profile.autoConnect) {
    lines.add('    autoConnect: true');
  }
  return '${lines.join('\n')}\n';
}

/// A single-quoted YAML scalar. The only escape a single-quoted string needs
/// is doubling a quote that appears inside it.
String _scalar(String value) => "'${value.replaceAll("'", "''")}'";

String _list(List<String> values) => '[${values.map(_scalar).join(', ')}]';

/// Deep-copies a `package:yaml` node tree into the plain `Map`/`List`/scalar
/// shape [Profile.fromJson] already knows how to read — the same shape
/// `jsonDecode` would have produced, so there is one reader for both.
Object? _plain(Object? node) {
  if (node is YamlMap) {
    return {
      for (final entry in node.entries) '${entry.key}': _plain(entry.value),
    };
  }
  if (node is YamlList) {
    return node.map(_plain).toList(growable: false);
  }
  return node;
}
