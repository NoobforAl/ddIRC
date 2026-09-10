import 'package:flutter/foundation.dart';
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
/// ## Passwords cross in, and never back out
///
/// The format reads credentials and never writes them. That asymmetry is the
/// whole design, and it is deliberate rather than an omission:
///
/// * **Reading** them means a file somebody writes by hand can carry a
///   complete network — paste the password in, import once, done. Refusing to
///   read one did not make anybody safer; it made them retype a password they
///   had already written down somewhere less careful than a file they control.
/// * **Writing** them would put a credential into every file the app hands
///   out, including the one exported to move a network between two of the
///   user's own devices and the QR code shown on a screen in a room. That is a
///   different act with a different audience, and [writeIrcConfig] does not do
///   it — see the round-trip test that asserts the word never appears.
///
/// So an imported password goes straight to the platform keychain, exactly
/// where the editor would have put it, and the file it came from is the only
/// copy that stays in the clear. A `.irc` file carrying one is as sensitive as
/// the password it holds, and the import screen says so.
const _kVersion = 1;

/// A network read out of a `.irc` file, with whatever credentials rode along.
///
/// Separate from [Profile] rather than fields on it, because [Profile] is the
/// object the app keeps in memory for the life of the session and the one
/// thing it must never hold is a password — see [ProfileStore], which splits
/// configuration from secrets for exactly this reason. This type exists only
/// between parsing a file and saving what it named: short-lived, never stored,
/// never handed to anything that persists.
@immutable
class ImportedNetwork {
  const ImportedNetwork({
    required this.profile,
    this.serverPassword,
    this.saslPassword,
    this.nickservPassword,
    this.proxyPassword,
  });

  /// The network itself, already carrying a fresh local id.
  final Profile profile;

  /// Sent as `PASS` before registration. `password` in the file, which is what
  /// the IRC protocol calls it and what every other client's config calls it.
  final String? serverPassword;

  /// The password for [Profile.saslAccount].
  final String? saslPassword;

  /// Used to identify to NickServ when SASL was not accepted.
  final String? nickservPassword;

  /// The credential for this network's own proxy, when it brings one.
  final String? proxyPassword;

  /// Whether the file this came from had a secret in it.
  ///
  /// Drives the warning on the import screen. A file with no password in it
  /// is an address book and needs no caveat; one with a password in it is a
  /// credential sitting in the clear on a disk, and saying so once at the
  /// moment of import is the only chance to say it usefully.
  bool get carriesSecret =>
      serverPassword != null ||
      saslPassword != null ||
      nickservPassword != null ||
      proxyPassword != null;

  ImportedNetwork withProfile(Profile profile) => ImportedNetwork(
    profile: profile,
    serverPassword: serverPassword,
    saslPassword: saslPassword,
    nickservPassword: nickservPassword,
    proxyPassword: proxyPassword,
  );
}

/// Turn a `.irc` file's text — or whatever a scanned QR code decoded to —
/// into networks ready to review and save.
///
/// Tolerant the way [Profile.fromJson] is tolerant: one malformed network
/// entry is dropped rather than failing the whole import, because a file
/// somebody shared with five networks in it should not be refused over one
/// bad line. Throws [FormatException] only when there is nothing to salvage
/// at all — the text is not YAML, or names no networks, or names none that
/// survived being read.
///
/// That last case used to return an empty list, which the import screen then
/// opened with nothing in it to show. A file whose every entry was rejected
/// has failed, and it says so here rather than looking like an import that
/// found no networks worth mentioning.
///
/// Each network gets a fresh [ProfileStore.newId] rather than keeping
/// whatever id the exporting device wrote: that id is local housekeeping —
/// it keys a keychain entry on the device that saved it — and carrying one
/// over would risk two unrelated networks, saved on two different phones,
/// ending up addressed by the same key on a third.
List<ImportedNetwork> parseIrcConfig(String source) {
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

  final imported = <ImportedNetwork>[];
  for (final entry in networks) {
    if (entry is! YamlMap) continue;
    final map = _plain(entry) as Map<String, Object?>;
    final profile = Profile.fromJson({...map, 'id': ProfileStore.newId()});
    if (profile == null) continue;
    imported.add(
      ImportedNetwork(
        profile: profile,
        // `password` is the spelling the protocol uses for PASS, and the one
        // somebody writing this file by hand will reach for first;
        // `serverPassword` matches what the editor labels the same field.
        // Both mean the same thing, and the explicit one wins.
        serverPassword: _secret(map['serverPassword']) ?? _secret(
          map['password'],
        ),
        saslPassword: _secret(map['saslPassword']),
        nickservPassword: _secret(map['nickservPassword']),
        proxyPassword: _secret(
          map['proxy'] is Map ? (map['proxy']! as Map)['password'] : null,
        ),
      ),
    );
  }

  if (imported.isEmpty) {
    throw const FormatException(
      'Every network in this file was missing something. Each one needs a '
      'host, a nickname, and a port written as a plain number.',
    );
  }
  return List.unmodifiable(imported);
}

/// A credential as written, or null if there is nothing usable there.
///
/// A number is accepted and stringified because an all-digit password written
/// unquoted is read by YAML as an integer, and silently dropping it would be
/// the same trap a quoted `port` already sets — see the format docs.
String? _secret(Object? value) {
  if (value is String) return value.isEmpty ? null : value;
  if (value is num) return '$value';
  return null;
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
///
/// **No credential is ever written here**, and none can be: this takes
/// [Profile]s, and a [Profile] has nowhere to hold one. Reading a password is
/// something the format does; producing one is not. See [ImportedNetwork].
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
