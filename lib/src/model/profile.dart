import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/types.dart';

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

  bool get usesSasl => (saslAccount ?? '').isNotEmpty;

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
    );
  }

  /// Build the config the core connects with.
  ///
  /// The password is passed in rather than stored, so it exists only for the
  /// duration of the connect call — the core zeroizes it after SASL.
  ServerConfig toConfig({String? saslPassword}) {
    final fallback = altNicks.isEmpty ? ['${nickname}_'] : altNicks;
    return ServerConfig(
      host: host,
      port: port,
      nickname: nickname,
      altNicks: fallback,
      channels: channels,
      saslAccount: (saslAccount ?? '').isEmpty ? null : saslAccount,
      saslPassword: (saslPassword ?? '').isEmpty ? null : saslPassword,
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
  /// `password` distinguishes three cases: null leaves whatever is stored
  /// alone (so editing a profile does not silently wipe its credential), an
  /// empty string clears it, and anything else replaces it.
  Future<void> save(Profile profile, {String? password}) async {
    final index = _profiles.indexWhere((p) => p.id == profile.id);
    if (index == -1) {
      _profiles = [..._profiles, profile];
    } else {
      _profiles = [..._profiles]..[index] = profile;
    }
    notifyListeners();

    if (password != null) {
      await _writeSecret(profile.id, password);
    }
    // A profile with no SASL account cannot use a password; drop any that a
    // previous configuration left behind rather than keeping an orphan.
    if (!profile.usesSasl) await _writeSecret(profile.id, '');

    await _write();
  }

  Future<void> remove(String id) async {
    _profiles = _profiles.where((p) => p.id != id).toList();
    notifyListeners();
    await _writeSecret(id, '');
    await _write();
  }

  /// The stored password, or null. Read at connect time and not retained.
  Future<String?> passwordFor(String id) async {
    try {
      return await _secrets.read(key: '$_secretPrefix$id');
    } catch (e) {
      debugPrint('could not read stored credential: $e');
      return null;
    }
  }

  Future<void> _writeSecret(String id, String value) async {
    final key = '$_secretPrefix$id';
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
