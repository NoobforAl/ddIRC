import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/types.dart' as core;
import 'profile.dart';
import 'tor.dart';

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
///
/// All three are overridden by [ProxyRoute.builtIn]. That is the one exception
/// to everything above, and it is deliberate: bundled Tor is not an address
/// this app happens to be pointed at, it is an answer to "does anything I do
/// leave this machine in the clear", and a per-network opt-out would make that
/// answer "mostly". See [ProxySettings.overridesProfiles].
enum ProxyMode {
  /// Whatever the app is set to. The default, and what every existing profile
  /// is read back as.
  followDefault('App default'),

  /// Never proxy this server, whatever the app-wide proxy is set to. Yields to
  /// built-in Tor, which nothing is allowed to route around.
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

/// Where the app-wide proxy comes from.
///
/// The three answers are genuinely different things rather than three ways of
/// writing an address, which is why this is an enum and not a nullable field.
/// [builtIn] has no address to type and no credential to store; [manual] has
/// both; [off] is a decision, and one worth being able to see.
enum ProxyRoute {
  /// Connections go direct.
  off('Off'),

  /// The Tor that ships inside the app, on a loopback port it chose. Beta.
  builtIn('Built-in Tor'),

  /// A SOCKS5 proxy the user runs — their own Tor on 9050, an SSH tunnel, a
  /// company proxy. This is what the setting has always been.
  manual('My own proxy');

  const ProxyRoute(this.label);

  final String label;

  static ProxyRoute byName(Object? name) => ProxyRoute.values.firstWhere(
    (r) => r.name == name,
    orElse: () => ProxyRoute.off,
  );
}

/// A proxy was asked for and is not there.
///
/// Thrown rather than resolved to null, and that distinction is the point.
/// Null means *direct*, which is a legitimate answer for a profile set to
/// connect directly — and if a missing proxy also resolved to null, a user who
/// turned Tor on and watched it fail to start would be connected in clear,
/// over exactly the route they had just said not to use.
///
/// The app promises no proxy fallback. This is where that promise is kept.
class ProxyUnavailable implements Exception {
  const ProxyUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
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
  ProxySettings._(this._prefs, this._secrets, this._tor);

  static const _kEnabled = 'proxy.enabled';
  static const _kRoute = 'proxy.route.v1';
  static const _kEndpoint = 'proxy.endpoint.v1';
  static const _secretKey = 'proxy.app-default';

  final SharedPreferences? _prefs;
  final FlutterSecureStorage _secrets;

  /// Where [ProxyRoute.builtIn] gets its port from.
  ///
  /// Optional so the model can be built without one — the tests do, and so
  /// would any host with no Tor in it. A null Tor means the built-in route is
  /// never available, which [ProxyUnavailable] then reports honestly instead
  /// of quietly connecting direct.
  final TorSettings? _tor;

  ProxyRoute _route = ProxyRoute.off;
  ProxyEndpoint? _endpoint;

  /// Where connections go. Off by default: a proxy nobody asked for is a
  /// proxy that will not be running.
  ProxyRoute get route => _route;

  /// Whether anything at all is in force. Kept for the callers that only want
  /// that much, and for the preference an older version of the app wrote.
  bool get enabled => _route != ProxyRoute.off;

  /// The manual address, whether or not it is the route in use — so switching
  /// to Tor and back does not mean typing it again.
  ProxyEndpoint? get endpoint => _endpoint;

  /// The proxy actually in force, or null for a direct connection.
  ///
  /// Null for [ProxyRoute.builtIn] while Tor is still starting, which is *not*
  /// the same as direct — see [waiting], and see [resolveProxy], which refuses
  /// rather than resolving that gap to a direct connection.
  ProxyEndpoint? get active => switch (_route) {
    ProxyRoute.off => null,
    ProxyRoute.manual => _endpoint,
    ProxyRoute.builtIn => switch (_tor?.port) {
      final int port => ProxyEndpoint(host: '127.0.0.1', port: port),
      null => null,
    },
  };

  /// Whether this route ignores what individual networks asked for.
  ///
  /// True for [ProxyRoute.builtIn] and nothing else. A manual proxy is a
  /// default, and a network that says "Direct" or brings its own address means
  /// it. Built-in Tor is not a default: someone who switched it on wants their
  /// address off the wire, and a single network quietly exempting itself would
  /// put it back there — announced to that server as a NOTICE, in a WHOIS
  /// reply, and in whatever the network logs. There is no per-network way to
  /// want that a little.
  bool get overridesProfiles => _route == ProxyRoute.builtIn;

  /// A proxy is wanted and is not there. Nothing may connect.
  bool get waiting => _route == ProxyRoute.builtIn && active == null;

  static Future<ProxySettings> load({TorSettings? tor}) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('proxy settings unavailable, starting direct: $e');
    }
    final settings = ProxySettings._(prefs, const FlutterSecureStorage(), tor);
    settings._read();
    // The address of the built-in route appears and disappears with Tor, so
    // anything reading `active` has to be told when that happens.
    tor?.addListener(settings.notifyListeners);
    return settings;
  }

  void _read() {
    final prefs = _prefs;
    if (prefs == null) return;
    final stored = prefs.getString(_kRoute);
    // Before there was a route there was a bool, and a setting saved by that
    // version has to keep working: a proxy that switched itself off on upgrade
    // would send the next connection somewhere the user did not choose.
    _route = stored != null
        ? ProxyRoute.byName(stored)
        : (prefs.getBool(_kEnabled) ?? false)
        ? ProxyRoute.manual
        : ProxyRoute.off;

    final raw = prefs.getString(_kEndpoint);
    if (raw != null) {
      try {
        _endpoint = ProxyEndpoint.fromJson(jsonDecode(raw));
      } catch (e) {
        debugPrint('proxy address could not be read, ignoring it: $e');
      }
    }
    // A manual route with nothing behind it would fail every connection for a
    // reason the settings screen does not show. Treat it as off.
    if (_route == ProxyRoute.manual && _endpoint == null) {
      _route = ProxyRoute.off;
    }
  }

  /// Switch to the bundled Tor, or away from it.
  ///
  /// Separate from [save] because there is nothing to type and nothing to
  /// validate — the address is whichever port Tor bound — and running the
  /// address form for a route that has no address would be theatre.
  Future<void> useBuiltIn(bool value) async {
    _route = value
        ? ProxyRoute.builtIn
        // Back to the manual address if there is one, rather than straight to
        // off: turning Tor off should leave the setting where it was before
        // Tor, not silently discard a proxy the user configured.
        : (_endpoint != null ? ProxyRoute.manual : ProxyRoute.off);
    notifyListeners();
    await _writeRoute();
  }

  Future<void> _writeRoute() async {
    await _prefs?.setString(_kRoute, _route.name);
    // Kept in step for a downgrade, which would otherwise read a route it does
    // not know beside a bool that contradicts it.
    await _prefs?.setBool(_kEnabled, _route != ProxyRoute.off);
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
    _route = (enabled && endpoint != null) ? ProxyRoute.manual : ProxyRoute.off;
    notifyListeners();

    if (password != null) await _writeSecret(password);
    // No username means no password can be sent, so an orphan is dead weight
    // in the keychain and nothing else.
    if (!(endpoint?.usesAuth ?? false)) await _writeSecret('');

    await _writeRoute();
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
///
/// Throws [ProxyUnavailable] when a proxy was asked for and is not there —
/// which today means the bundled Tor is switched on but has not come up.
/// Returning null there would be the one bug in this file worth fearing: the
/// connection would succeed, in clear, over the route the user had just said
/// not to use, and nothing on screen would look wrong.
Future<core.ProxyConfig?> resolveProxy(
  Profile profile,
  ProxySettings settings,
  ProfileStore profiles,
) async {
  // Built-in Tor first, and without consulting the profile at all.
  //
  // This is the whole of the override, and it is one branch on purpose: every
  // line below reads a per-network preference, and there is no reading of one
  // that can put a connection outside Tor while Tor is on. A network set to
  // "Direct" is not asking to leak — it is asking not to use the *app-wide
  // address*, which is a different question and one that stops being asked
  // here.
  if (settings.overridesProfiles) {
    final tor = settings.active;
    if (tor == null) {
      throw const ProxyUnavailable(
        'Built-in Tor is switched on but is not running, so there is nothing '
        'to connect through. Connecting directly would go around it, which is '
        'not something ddIRC will do on its own — check Tor in App settings.',
      );
    }
    // No credentials: this is loopback, to a Tor this process started, and
    // there is nobody in between for a username to prove anything to.
    return core.ProxyConfig(host: tor.host, port: tor.port);
  }

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
