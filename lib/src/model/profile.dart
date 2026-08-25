import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/types.dart';
import 'proxy.dart';

/// A saved server, ready to connect to.
///
/// Everything here except the SASL password is ordinary configuration and is
/// stored as such. The password never lives on this object beyond the moment
/// it is being read from or written to secure storage — see [ProfileStore].
@immutable
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.nickname,
    this.altNicks = const [],
    this.channels = const [],
    this.saslAccount,
    this.proxyMode = ProxyMode.followDefault,
    this.proxy,
    this.autoConnect = false,
  });

  /// Stable across renames, because it keys both the stored password and the
  /// per-channel notification settings.
  final String id;

  /// What the user calls this network. Defaults to the host.
  final String name;

  final String host;
  final int port;
  final String nickname;
  final List<String> altNicks;
  final List<String> channels;
  final String? saslAccount;

  /// Where this server's proxy comes from. Defaults to the app-wide setting,
  /// which is also what a profile saved before proxies existed reads back as.
  final ProxyMode proxyMode;

  /// This server's own proxy. Only consulted when [proxyMode] is
  /// [ProxyMode.custom]; kept when it is not, so switching away and back does
  /// not mean typing the address again.
  final ProxyEndpoint? proxy;

  /// Connect this network when the app starts.
  ///
  /// Off, and off for every profile saved before this existed. Launching into
  /// connections nobody asked for is the kind of default that has to be opted
  /// into rather than out of.
  final bool autoConnect;

  bool get usesSasl => (saslAccount ?? '').isNotEmpty;

  /// Whether this profile needs its own proxy password in the keychain.
  bool get usesProxyAuth =>
      proxyMode == ProxyMode.custom && (proxy?.usesAuth ?? false);

  /// The two-letter mark shown on the network rail.
  ///
  /// Initials of the name, so `Libera.Chat` reads `LC` and `snoonet` reads
  /// `SN` — distinguishable at a glance without an icon set.
  String get initials {
    final words = name
        .split(RegExp(r'[\s._-]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      final word = words.first;
      return (word.length == 1 ? word : word.substring(0, 2)).toUpperCase();
    }
    return (words[0][0] + words[1][0]).toUpperCase();
  }

  Profile copyWith({
    String? name,
    String? host,
    int? port,
    String? nickname,
    List<String>? altNicks,
    List<String>? channels,
    String? saslAccount,
    ProxyMode? proxyMode,
    ProxyEndpoint? proxy,
    bool? autoConnect,
  }) {
    return Profile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      nickname: nickname ?? this.nickname,
      altNicks: altNicks ?? this.altNicks,
      channels: channels ?? this.channels,
      saslAccount: saslAccount ?? this.saslAccount,
      proxyMode: proxyMode ?? this.proxyMode,
      proxy: proxy ?? this.proxy,
      autoConnect: autoConnect ?? this.autoConnect,
    );
  }

  /// Build the config the core connects with.
  ///
  /// Both secrets are passed in rather than stored, so they exist only for the
  /// duration of the connect call — the core zeroizes them once used.
  ///
  /// `proxy` is already resolved: `resolveProxy` settles this profile's mode
  /// against the app-wide setting first, so what arrives here is the single
  /// answer and not a policy for the core to interpret.
  ServerConfig toConfig({String? saslPassword, ProxyConfig? proxy}) {
    final fallback = altNicks.isEmpty ? ['${nickname}_'] : altNicks;
    return ServerConfig(
      host: host,
      port: port,
      nickname: nickname,
      altNicks: fallback,
      channels: channels,
      saslAccount: (saslAccount ?? '').isEmpty ? null : saslAccount,
      saslPassword: (saslPassword ?? '').isEmpty ? null : saslPassword,
      proxy: proxy,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'nickname': nickname,
    'altNicks': altNicks,
    'channels': channels,
    'saslAccount': saslAccount,
    'proxyMode': proxyMode.name,
    'proxy': proxy?.toJson(),
    'autoConnect': autoConnect,
  };

  static Profile? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final host = json['host'];
    final nickname = json['nickname'];
    final port = json['port'];
    // A malformed entry is dropped rather than crashing the app on launch:
    // one bad record must not cost the user every other profile.
    if (id is! String || host is! String || nickname is! String) return null;
    if (port is! int) return null;

    return Profile(
      id: id,
      name: json['name'] is String ? json['name']! as String : host,
      host: host,
      port: port,
      nickname: nickname,
      altNicks: _strings(json['altNicks']),
      channels: _strings(json['channels']),
      saslAccount: json['saslAccount'] is String
          ? json['saslAccount']! as String
          : null,
      // Absent on every profile saved before proxies existed, which is
      // exactly the default: follow the app, which is off.
      proxyMode: ProxyMode.byName(json['proxyMode']),
      proxy: ProxyEndpoint.fromJson(json['proxy']),
      // Anything but a stored `true` is false, so a profile from before this
      // existed - or one with a corrupted value - stays off.
      autoConnect: json['autoConnect'] == true,
    );
  }

  static List<String> _strings(Object? value) => value is List
      ? value.whereType<String>().toList(growable: false)
      : const [];
}

/// The saved profiles, and the passwords that belong to them.
///
/// Two stores, deliberately: configuration in `shared_preferences`, which is
/// plain, and secrets in `flutter_secure_storage`, which is the platform
/// keychain. Nothing that authenticates the user is ever written to the former.
class ProfileStore extends ChangeNotifier {
  ProfileStore._(this._prefs, this._secrets);

  static const _kProfiles = 'profiles.v1';
  static const _secretPrefix = 'sasl.';
  static const _proxySecretPrefix = 'proxy.server.';

  final SharedPreferences? _prefs;
  final FlutterSecureStorage _secrets;

  List<Profile> _profiles = const [];

  List<Profile> get profiles => List.unmodifiable(_profiles);
  bool get isEmpty => _profiles.isEmpty;

  static Future<ProfileStore> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('profiles unavailable, starting empty: $e');
    }
    final store = ProfileStore._(prefs, const FlutterSecureStorage());
    store._read();
    return store;
  }

  void _read() {
    final raw = _prefs?.getString(_kProfiles);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _profiles = decoded
          .whereType<Map<String, Object?>>()
          .map(Profile.fromJson)
          .whereType<Profile>()
          .toList();
    } catch (e) {
      debugPrint('profiles could not be read, starting empty: $e');
    }
  }

  Future<void> _write() async {
    await _prefs?.setString(
      _kProfiles,
      jsonEncode(_profiles.map((p) => p.toJson()).toList()),
    );
  }

  Profile? byId(String id) {
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// Add or replace a profile, optionally rewriting its stored password.
  ///
  /// `password` and `proxyPassword` each distinguish three cases: null leaves
  /// whatever is stored alone (so editing a profile does not silently wipe a
  /// credential), an empty string clears it, and anything else replaces it.
  Future<void> save(
    Profile profile, {
    String? password,
    String? proxyPassword,
  }) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) {
      _profiles = [..._profiles, profile];
    } else {
      _profiles = [..._profiles]..[index] = profile;
    }
    notifyListeners();

    if (password != null) {
      await _writeSecret(_secretPrefix, profile.id, password);
    }
    if (proxyPassword != null) {
      await _writeSecret(_proxySecretPrefix, profile.id, proxyPassword);
    }
    // A profile with no SASL account cannot use a password; drop any that a
    // previous configuration left behind rather than keeping an orphan. The
    // same goes for a proxy that no longer authenticates, or is no longer
    // this profile's own.
    if (!profile.usesSasl) await _writeSecret(_secretPrefix, profile.id, '');
    if (!profile.usesProxyAuth) {
      await _writeSecret(_proxySecretPrefix, profile.id, '');
    }

    await _write();
  }

  Future<void> remove(String id) async {
    _profiles = _profiles.where((p) => p.id != id).toList();
    notifyListeners();
    await _writeSecret(_secretPrefix, id, '');
    await _writeSecret(_proxySecretPrefix, id, '');
    await _write();
  }

  /// The stored SASL password, or null. Read at connect time and not retained.
  Future<String?> passwordFor(String id) => _readSecret(_secretPrefix, id);

  /// The stored password for this profile's own proxy, or null.
  Future<String?> proxyPasswordFor(String id) =>
      _readSecret(_proxySecretPrefix, id);

  Future<String?> _readSecret(String prefix, String id) async {
    try {
      return await _secrets.read(key: '$prefix$id');
    } catch (e) {
      debugPrint('could not read stored credential: $e');
      return null;
    }
  }

  Future<void> _writeSecret(String prefix, String id, String value) async {
    final key = '$prefix$id';
    try {
      if (value.isEmpty) {
        await _secrets.delete(key: key);
      } else {
        await _secrets.write(key: key, value: value);
      }
    } catch (e) {
      // Failing to store a password must not lose the profile itself; the
      // user is told at the point of failure by the editor.
      debugPrint('could not store credential: $e');
    }
  }

  /// Identifier for a new profile.
  ///
  /// Derived from the clock and the list length rather than a UUID package:
  /// it only has to be unique within one user's own profile list.
  static String newId() =>
      'p${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

/// Makes [ProfileStore] available to the widget tree.
class ProfileScope extends InheritedNotifier<ProfileStore> {
  const ProfileScope({
    super.key,
    required ProfileStore store,
    required super.child,
  }) : super(notifier: store);

  static ProfileStore of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ProfileScope>();
    assert(scope?.notifier != null, 'No ProfileScope above this widget');
    return scope!.notifier!;
  }
}
