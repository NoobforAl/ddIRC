import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Platforms `local_auth` actually serves.
///
/// Linux has no implementation at all — not merely unenrolled, there is no
/// API this could call into — so the setting does not appear there, rather
/// than appearing and doing nothing.
bool appLockSupportedOn(TargetPlatform platform) =>
    platform != TargetPlatform.linux;

/// Whether ddIRC asks for biometrics (or the device PIN/pattern/password)
/// before it can be used.
///
/// A UI gate, not a data-at-rest control: the platform keychain already
/// protects stored secrets whether or not this is turned on, and connections
/// already open keep running behind the lock screen. This only decides what
/// is on screen. Off by default, like every switch here.
class AppLockSettings extends ChangeNotifier {
  AppLockSettings._(this._prefs);

  static const _kEnabled = 'app_lock.enabled';

  final SharedPreferences? _prefs;
  bool _enabled = false;

  /// What the user asked for, folded against platform support.
  ///
  /// A stored `true` carried in from another platform — a synced settings
  /// file, a restored backup — must never leave this platform unable to open
  /// the app it locked. There is no biometric API to fall back to on Linux,
  /// only none, so the honest answer there is always off.
  bool get enabled => _enabled && appLockSupportedOn(defaultTargetPlatform);

  static Future<AppLockSettings> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('app lock preference unavailable, starting off: $e');
    }
    final settings = AppLockSettings._(prefs);
    settings._enabled = prefs?.getBool(_kEnabled) ?? false;
    return settings;
  }

  /// Turn it on or off. Writes through immediately.
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    await _prefs?.setBool(_kEnabled, value);
    notifyListeners();
  }
}

/// Makes [AppLockSettings] available to the widget tree.
class AppLockScope extends InheritedNotifier<AppLockSettings> {
  const AppLockScope({
    super.key,
    required AppLockSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static AppLockSettings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppLockScope>();
    assert(scope?.notifier != null, 'No AppLockScope above this widget');
    return scope!.notifier!;
  }
}
