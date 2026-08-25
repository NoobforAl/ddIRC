import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/types.dart' as core;
import 'profile.dart';

/// Where a server gets its proxy from.
///
/// The app has one proxy setting; a server may take it, refuse it, or bring its
/// own. Global-as-default is the arrangement every other client uses and the
/// least surprising of the two the design note weighed: a single setting covers
/// the common case of "put everything through Tor", and the override exists
/// because a LAN server or a private bouncer is often reachable only directly.
///
/// The alternative — a global proxy that admits no exceptions — was rejected
/// because it makes one network's requirements silently break every other
/// network, with no way to see why. [direct] is deliberately an explicit
/// choice, spelled out in the UI, rather than something a blank field does by
/// accident: turning a proxy off for one server should take saying so.
enum ProxyMode {
  /// Whatever the app is set to. The default, and what every existing profile
  /// is read back as.
  followDefault('App default'),

  /// Never proxy this server, whatever the app is set to.
  direct('Direct'),

  /// This server's own proxy.
  custom('Custom');

  const ProxyMode(this.label);

  final String label;

  static ProxyMode byName(Object? name) => ProxyMode.values.firstWhere(
    (m) => m.name == name,
    orElse: () => ProxyMode.followDefault,
  );
}

/// A SOCKS5 proxy, as configured. The password is not here — it lives in the
/// platform keychain, exactly like the SASL one.
@immutable
class ProxyEndpoint {
  const ProxyEndpoint({required this.host, required this.port, this.username});

  final String host;
  final int port;
  final String? username;

  bool get usesAuth => (username ?? '').isNotEmpty;

  /// `host:port`, as it would be typed.
  String get label => '$host:$port';

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'username': username,
  };

  static ProxyEndpoint? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    final port = json['port'];
    if (host is! String || port is! int) return null;
    final username = json['username'];
    return ProxyEndpoint(
      host: host,
      port: port,
      username: username is String && username.isNotEmpty ? username : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ProxyEndpoint &&
      other.host == host &&
      other.port == port &&
      other.username == username;

  @override
  int get hashCode => Object.hash(host, port, username);
}

/// The app-wide proxy, and the password that belongs to it.
///
/// Its own model rather than a few more fields on `AppSettings`, because
/// `AppSettings` says of itself that none of it reaches the network — and this
/// decides where every byte goes. It is also the only preference here with a
/// secret attached, which means two stores rather than one.
class ProxySettings extends ChangeNotifier {
  ProxySettings._(this._prefs, this._secrets);

  static const _kEnabled = 'proxy.enabled';
  static const _kEndpoint = 'proxy.endpoint.v1';
  static const _secretKey = 'proxy.app-default';

  final SharedPreferences? _prefs;
  final FlutterSecureStorage _secrets;

  bool _enabled = false;
  ProxyEndpoint? _endpoint;

  /// Off. A proxy nobody asked for is a proxy that will not be running.
  bool get enabled => _enabled;

  /// What is configured, whether or not it is switched on — so turning the
  /// switch back on does not mean typing the address again.
  ProxyEndpoint? get endpoint => _endpoint;

  /// The proxy actually in force, or null. This is the one callers want.
  ProxyEndpoint? get active => _enabled ? _endpoint : null;

  static Future<ProxySettings> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('proxy settings unavailable, starting direct: $e');
    }
    final settings = ProxySettings._(prefs, const FlutterSecureStorage());
    settings._read();
    return settings;
  }

  void _read() {
    final prefs = _prefs;
    if (prefs == null) return;
    _enabled = prefs.getBool(_kEnabled) ?? false;
    final raw = prefs.getString(_kEndpoint);
    if (raw == null) return;
    try {
      _endpoint = ProxyEndpoint.fromJson(jsonDecode(raw));
    } catch (e) {
      debugPrint('proxy address could not be read, ignoring it: $e');
    }
    // A switch that is on with nothing behind it would fail every connection
    // for a reason the settings screen does not show. Treat it as off.
    if (_endpoint == null) _enabled = false;
  }

  /// Replace the app-wide proxy.
  ///
  /// `password` follows the same three-way convention as the profile store:
  /// null leaves the stored one alone, empty clears it, anything else replaces
  /// it. Editing the port must not silently drop a credential.
  Future<void> save({
    required bool enabled,
    ProxyEndpoint? endpoint,
    String? password,
  }) async {
    _endpoint = endpoint;
    _enabled = enabled && endpoint != null;
    notifyListeners();

    if (password != null) await _writeSecret(password);
    // No username means no password can be sent, so an orphan is dead weight
    // in the keychain and nothing else.
    if (!(endpoint?.usesAuth ?? false)) await _writeSecret('');

    await _prefs?.setBool(_kEnabled, _enabled);
    if (endpoint == null) {
      await _prefs?.remove(_kEndpoint);
    } else {
      await _prefs?.setString(_kEndpoint, jsonEncode(endpoint.toJson()));
    }
  }

  /// The stored password, or null. Read at connect time and not retained.
  Future<String?> password() async {
    try {
      return await _secrets.read(key: _secretKey);
    } catch (e) {
      debugPrint('could not read the stored proxy credential: $e');
      return null;
    }
  }

  Future<void> _writeSecret(String value) async {
    try {
      if (value.isEmpty) {
        await _secrets.delete(key: _secretKey);
      } else {
        await _secrets.write(key: _secretKey, value: value);
      }
    } catch (e) {
      debugPrint('could not store the proxy credential: $e');
    }
  }
}

/// The proxy a profile actually connects through, ready for the core.
///
/// One function, because the two halves of the answer come from different
/// places — which endpoint, and whose password — and getting them from
/// different places at different call sites is how a profile ends up dialling
/// its own proxy with the app-wide credential.
///
/// Returns null for a direct connection, which the core reads as exactly that.
Future<core.ProxyConfig?> resolveProxy(
  Profile profile,
  ProxySettings settings,
  ProfileStore profiles,
) async {
  final (endpoint, password) = switch (profile.proxyMode) {
    ProxyMode.direct => (null, null),
    ProxyMode.custom => (
      profile.proxy,
      profile.proxy?.usesAuth ?? false
          ? await profiles.proxyPasswordFor(profile.id)
          : null,
    ),
    ProxyMode.followDefault => (
      settings.active,
      settings.active?.usesAuth ?? false ? await settings.password() : null,
    ),
  };

  if (endpoint == null) return null;
  return core.ProxyConfig(
    host: endpoint.host,
    port: endpoint.port,
    username: endpoint.username,
    password: password,
  );
}

/// `host:port` for a proxy a live connection is actually using.
///
/// Mirrors [ProxyEndpoint.label] for the core's own type, so the same address
/// is written the same way wherever it is shown.
extension ProxyConfigLabel on core.ProxyConfig {
  String get label => '$host:$port';
}

/// How one network is reaching its server, for the rail's tooltip.
///
/// Takes the proxy from the config the connection was *opened with*, not from
/// the current settings. Those can be changed while a connection is up, and
/// the gap between what is configured and what is actually in force is exactly
/// what this exists to expose.
///
/// Says which either way, including when the answer is "directly". A label
/// that only appears when a proxy is in use tells you nothing by its absence,
/// and the failure worth catching here is believing a connection is proxied
/// when it is not.
String networkTooltip(
  String name,
  core.ProxyConfig? proxy, {
  bool live = true,
}) {
  // Nothing has been reached yet, so there is no route to report. What an
  // unconnected profile *would* use is the profile editor's business.
  if (!live) return name;
  return '$name\n${proxy == null ? 'Connected directly' : 'Through ${proxy.label}'}';
}

/// Makes [ProxySettings] available to the widget tree.
class ProxyScope extends InheritedNotifier<ProxySettings> {
  const ProxyScope({
    super.key,
    required ProxySettings settings,
    required super.child,
  }) : super(notifier: settings);

  static ProxySettings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ProxyScope>();
    assert(scope?.notifier != null, 'No ProxyScope above this widget');
    return scope!.notifier!;
  }
}
