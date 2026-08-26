import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/tor.dart' as core;

/// How far along the bundled Tor is, as the app says it.
///
/// The app's own type rather than the generated one, because it has a state
/// the core does not: **off**. The core can only describe a Tor that is
/// running, and "not running" is the state this spends most of its life in.
@immutable
class TorProgress {
  const TorProgress({
    required this.ready,
    required this.progress,
    required this.summary,
    this.blocked,
  });

  /// Not running at all.
  static const off = TorProgress(ready: false, progress: 0, summary: 'Off');

  /// Connections through it will now succeed.
  final bool ready;

  /// 0.0 to 1.0.
  final double progress;

  /// One line, from Tor, in its words.
  final String summary;

  /// Why it is stuck, when Tor knows — a censored network, no route out, a
  /// clock too far off for anything to verify. The only part of this a user
  /// can act on, so it is the part shown in full.
  final String? blocked;
}

/// The bundled Tor — beta.
///
/// Owns one question: is Tor running, and where. Everything about *using* it
/// is the proxy model's business, and deliberately so — this ends at a port
/// number, and [ProxySettings] decides whether anything goes through it.
///
/// That split is the whole reason bundling Tor was a small change. The app has
/// been able to reach Tor through a SOCKS5 proxy since the proxy setting
/// existed; what was missing was Tor. So this supplies one, on loopback,
/// speaking the protocol the app already speaks, and nothing downstream had to
/// learn a new way to connect.
class TorSettings extends ChangeNotifier {
  TorSettings._(this._prefs);

  static const _kEnabled = 'tor.enabled';

  final SharedPreferences? _prefs;

  bool _enabled = false;
  int? _port;
  TorProgress _progress = TorProgress.off;
  String? _failure;
  StreamSubscription<core.TorStatus>? _following;

  /// What the user asked for. Off by default, like everything else here — a
  /// few hundred megabytes of directory consensus is not something to fetch
  /// on behalf of someone who never asked.
  bool get enabled => _enabled;

  /// The loopback port Tor is answering SOCKS5 on, or null if it is not up.
  int? get port => _port;

  /// Running, whatever state the bootstrap is in.
  bool get running => _port != null;

  TorProgress get progress => _progress;

  /// Why the last attempt to start failed, if it did. Cleared by a successful
  /// start, so a stale message cannot outlive the problem.
  String? get failure => _failure;

  /// Read the preference. Does **not** start Tor: at the point settings are
  /// loaded the native core is not up yet, and starting it needs the core.
  static Future<TorSettings> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('Tor preference unavailable, starting off: $e');
    }
    final tor = TorSettings._(prefs);
    tor._enabled = prefs?.getBool(_kEnabled) ?? false;
    return tor;
  }

  /// Start Tor if the user left it on. Called once, after the core is up and
  /// before anything auto-connects.
  ///
  /// Awaiting this matters: it returns as soon as the port is bound, which is
  /// long before Tor can carry anything, and a network dialled in that gap
  /// waits for the bootstrap rather than failing. What must not happen is a
  /// connection resolving its proxy before the port exists, because that is
  /// the one case that would look like "Tor is on" and travel direct.
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
    _progress = const TorProgress(
      ready: false,
      progress: 0,
      summary: 'Starting Tor',
    );
    notifyListeners();

    try {
      // Tor's own directory, inside the app's private storage. The consensus
      // it caches is public, but the guard list is not: it is a record of the
      // handful of relays this machine enters the network through, which is
      // exactly the thing worth keeping to itself.
      final base = await getApplicationSupportDirectory();
      _port = await core.torStart(dataDir: base.path);
    } catch (e) {
      _port = null;
      _failure = '$e';
      _progress = TorProgress.off;
      // Left switched on rather than silently flipped off: the user asked for
      // Tor, this failed to give it to them, and a switch that turns itself
      // off would hide that. Nothing connects through it while `port` is null.
      notifyListeners();
      return;
    }

    await _following?.cancel();
    _following = core.torStatusStream().listen((status) {
      _progress = TorProgress(
        ready: status.ready,
        progress: status.progress,
        summary: status.summary,
        blocked: status.blocked,
      );
      notifyListeners();
    }, onError: (Object e) => debugPrint('Tor status stream ended: $e'));
    notifyListeners();
  }

  Future<void> _stop() async {
    await _following?.cancel();
    _following = null;
    _port = null;
    _progress = TorProgress.off;
    notifyListeners();
    try {
      await core.torStop();
    } catch (e) {
      debugPrint('Tor did not stop cleanly: $e');
    }
  }

  @override
  void dispose() {
    unawaited(_following?.cancel());
    super.dispose();
  }
}

/// Makes [TorSettings] available to the widget tree.
class TorScope extends InheritedNotifier<TorSettings> {
  const TorScope({super.key, required TorSettings tor, required super.child})
    : super(notifier: tor);

  static TorSettings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<TorScope>();
    assert(scope?.notifier != null, 'No TorScope above this widget');
    return scope!.notifier!;
  }
}
