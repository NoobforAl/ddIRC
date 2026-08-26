import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/server.dart' as core;
import 'profile.dart';
import 'proxy.dart';

/// The IRC server that runs inside the app — beta.
///
/// Owns one question: is the server running, and on which port. What it does
/// beyond that is keep one profile pointed at it, because a server nobody can
/// reach is not a feature — and the address changes at every start, so the
/// profile cannot be something the user is asked to type.
///
/// The certificate is deliberately not here, or anywhere Dart can see it. The
/// server issues its own, and the client is told to trust it inside the
/// bridge, for exactly one loopback port. `extra_root_cert` stays absent from
/// the FFI type so that nothing a user can be talked into typing becomes a
/// trusted root.
class LocalServerSettings extends ChangeNotifier {
  LocalServerSettings._(this._prefs, this._profiles);

  static const _kEnabled = 'localServer.enabled';

  /// The one profile this manages.
  ///
  /// A fixed id rather than a fresh one per start, so the nickname, the
  /// channels and the notification settings survive the server being switched
  /// off and on — only the port is rewritten.
  static const profileId = 'local-server';

  final SharedPreferences? _prefs;
  final ProfileStore _profiles;

  bool _enabled = false;
  int? _port;
  String? _networkName;
  String? _failure;

  /// What the user asked for. Off by default.
  bool get enabled => _enabled;

  /// The loopback port it bound, or null if it is not running.
  int? get port => _port;

  /// What it calls the network, which is what labels it in the rail.
  String? get networkName => _networkName;

  bool get running => _port != null;

  /// Why the last attempt to start failed, if it did. Cleared by a successful
  /// start, so a stale message cannot outlive the problem.
  String? get failure => _failure;

  /// Read the preference. Does **not** start the server: at the point settings
  /// are loaded the native core is not up yet.
  static Future<LocalServerSettings> load({
    required ProfileStore profiles,
  }) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('local server preference unavailable, starting off: $e');
    }
    final settings = LocalServerSettings._(prefs, profiles);
    settings._enabled = prefs?.getBool(_kEnabled) ?? false;
    return settings;
  }

  /// Start it if the user left it on. Called once, after the core is up and
  /// before anything auto-connects.
  ///
  /// Awaiting this matters for the same reason it does for Tor, and more so:
  /// the profile's port is not known until the server has bound, so an
  /// auto-connect that ran first would dial last session's port.
  Future<void> startIfEnabled() async {
    if (!_enabled) return;
    await _start();
  }

  /// Turn it on or off. Writes through immediately.
  Future<void> setEnabled(bool value) async {
    if (value == _enabled && (!value || running)) return;
    _enabled = value;
    await _prefs?.setBool(_kEnabled, value);
    notifyListeners();
    if (value) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _start() async {
    _failure = null;
    try {
      // The server's own directory, inside the app's private storage. What
      // lives there is the certificate authority, which has to survive a
      // restart: re-issuing it would break every saved profile pointed here.
      final base = await getApplicationSupportDirectory();
      final info = await core.localServerStart(dataDir: base.path);
      _port = info.port;
      _networkName = info.networkName;
    } catch (e) {
      _port = null;
      _networkName = null;
      _failure = '$e';
      // Left switched on rather than silently flipped off: the user asked for
      // a server, this failed to give them one, and a switch that turns itself
      // off would hide that.
      notifyListeners();
      return;
    }
    await _writeProfile();
    notifyListeners();
  }

  Future<void> _stop() async {
    _port = null;
    _networkName = null;
    notifyListeners();
    try {
      await core.localServerStop();
    } catch (e) {
      debugPrint('the local server did not stop cleanly: $e');
    }
  }

  /// Point one profile at wherever the server just bound.
  ///
  /// Rewritten at every start because the port is asked for as `0` — nothing
  /// needs the number in advance, and a fixed port is a port something else
  /// may already be holding. Everything the user might have changed is kept.
  Future<void> _writeProfile() async {
    final existing = _profiles.byId(profileId);
    final port = _port;
    if (port == null) return;

    await _profiles.save(
      Profile(
        id: profileId,
        name: existing?.name ?? _networkName ?? 'Local',
        host: '127.0.0.1',
        port: port,
        // Whatever they are called elsewhere, so arriving on this network does
        // not mean being someone else. Falls back to the first saved profile's
        // nickname, and then to something rather than nothing.
        nickname: existing?.nickname ?? _borrowedNickname(),
        altNicks: existing?.altNicks ?? const [],
        channels: existing?.channels ?? const [],
        // Never proxied. `resolveProxy` refuses to proxy loopback anyway, but
        // saying so on the profile means the reason is visible in the editor
        // rather than only in the code.
        proxyMode: ProxyMode.direct,
        // On, because a server switched on that nothing connects to is a port
        // and a certificate in exchange for nothing.
        autoConnect: true,
      ),
    );
  }

  String _borrowedNickname() {
    for (final profile in _profiles.profiles) {
      if (profile.id != profileId && profile.nickname.isNotEmpty) {
        return profile.nickname;
      }
    }
    return 'you';
  }
}

/// Makes [LocalServerSettings] available to the widget tree.
class LocalServerScope extends InheritedNotifier<LocalServerSettings> {
  const LocalServerScope({
    super.key,
    required LocalServerSettings server,
    required super.child,
  }) : super(notifier: server);

  static LocalServerSettings of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<LocalServerScope>();
    assert(scope?.notifier != null, 'No LocalServerScope above this widget');
    return scope!.notifier!;
  }
}
