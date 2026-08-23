import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How loudly a conversation is allowed to ask for attention.
enum NotifyLevel {
  /// Every message raises the unread count.
  all('All messages'),

  /// Only messages that mention us count; ambient chatter stays quiet.
  mentions('Mentions only'),

  /// Nothing counts. The channel stays in the list, silently.
  none('Muted');

  const NotifyLevel(this.label);

  final String label;
}

/// How much vertical room a message gets.
enum Density {
  comfortable('Comfortable', 2.0),
  compact('Compact', 0.5);

  const Density(this.label, this.verticalPadding);

  final String label;
  final double verticalPadding;
}

/// Client-side preferences.
///
/// None of this reaches the network — it is purely how the client renders and
/// how loudly a channel may interrupt. Everything persists, because a setting
/// that resets on relaunch is worse than no setting at all.
class AppSettings extends ChangeNotifier {
  AppSettings._(this._prefs);

  static const _kTimestamps = 'ui.timestamps';
  static const _kTwentyFourHour = 'ui.clock24';
  static const _kSystemMessages = 'ui.systemMessages';
  static const _kDensity = 'ui.density';
  static const _kColors = 'ui.mircColors';
  static const _kNotifyPrefix = 'notify.';

  final SharedPreferences? _prefs;

  bool _showTimestamps = true;
  bool _twentyFourHour = true;
  bool _showSystemMessages = true;
  bool _renderColors = true;
  Density _density = Density.comfortable;
  final Map<String, NotifyLevel> _notify = {};

  /// Load from disk, falling back to defaults if the store is unavailable.
  ///
  /// A failure here must not stop the app from starting: preferences are a
  /// convenience, and losing them is not worth a black screen.
  static Future<AppSettings> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('settings unavailable, using defaults: $e');
    }
    final settings = AppSettings._(prefs);
    settings._read();
    return settings;
  }

  void _read() {
    final prefs = _prefs;
    if (prefs == null) return;
    _showTimestamps = prefs.getBool(_kTimestamps) ?? _showTimestamps;
    _twentyFourHour = prefs.getBool(_kTwentyFourHour) ?? _twentyFourHour;
    _showSystemMessages =
        prefs.getBool(_kSystemMessages) ?? _showSystemMessages;
    _renderColors = prefs.getBool(_kColors) ?? _renderColors;
    _density = Density.values.firstWhere(
      (d) => d.name == prefs.getString(_kDensity),
      orElse: () => _density,
    );
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_kNotifyPrefix)) continue;
      final level = NotifyLevel.values.firstWhere(
        (l) => l.name == prefs.getString(key),
        orElse: () => NotifyLevel.all,
      );
      _notify[key.substring(_kNotifyPrefix.length)] = level;
    }
  }

  bool get showTimestamps => _showTimestamps;
  bool get twentyFourHour => _twentyFourHour;
  bool get showSystemMessages => _showSystemMessages;
  bool get renderColors => _renderColors;
  Density get density => _density;

  set showTimestamps(bool value) => _set(_kTimestamps, value, () {
    _showTimestamps = value;
  });

  set twentyFourHour(bool value) => _set(_kTwentyFourHour, value, () {
    _twentyFourHour = value;
  });

  set showSystemMessages(bool value) => _set(_kSystemMessages, value, () {
    _showSystemMessages = value;
  });

  set renderColors(bool value) => _set(_kColors, value, () {
    _renderColors = value;
  });

  set density(Density value) => _set(_kDensity, value.name, () {
    _density = value;
  });

  /// The notification level for one conversation on one network.
  ///
  /// Scoped by profile, because `#chat` on two networks is two different
  /// rooms. Case-insensitive within a network, because IRC treats `#Foo` and
  /// `#foo` as the same channel and a server may use either casing.
  NotifyLevel notifyFor(String profileId, String conversation) =>
      _notify[_notifyKey(profileId, conversation)] ?? NotifyLevel.all;

  void setNotifyFor(String profileId, String conversation, NotifyLevel level) {
    final key = _notifyKey(profileId, conversation);
    if (notifyFor(profileId, conversation) == level) return;
    if (level == NotifyLevel.all) {
      _notify.remove(key);
      _prefs?.remove('$_kNotifyPrefix$key');
    } else {
      _notify[key] = level;
      _prefs?.setString('$_kNotifyPrefix$key', level.name);
    }
    notifyListeners();
  }

  /// Drop every notification setting belonging to a deleted profile.
  Future<void> forgetProfile(String profileId) async {
    final prefix = '$profileId/';
    final gone = _notify.keys.where((k) => k.startsWith(prefix)).toList();
    if (gone.isEmpty) return;
    for (final key in gone) {
      _notify.remove(key);
      await _prefs?.remove('$_kNotifyPrefix$key');
    }
    notifyListeners();
  }

  static String _notifyKey(String profileId, String conversation) =>
      '$profileId/${conversation.toLowerCase()}';

  void _set(String key, Object value, VoidCallback apply) {
    apply();
    // Fire and forget: the in-memory value is already authoritative, so a slow
    // or failing write never blocks the switch from moving.
    if (value is bool) {
      _prefs?.setBool(key, value);
    } else if (value is String) {
      _prefs?.setString(key, value);
    }
    notifyListeners();
  }

  /// Format a receipt time according to the clock preference.
  String formatTime(DateTime t) {
    final minute = t.minute.toString().padLeft(2, '0');
    if (_twentyFourHour) {
      return '${t.hour.toString().padLeft(2, '0')}:$minute';
    }
    final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$hour:$minute ${t.hour < 12 ? 'am' : 'pm'}';
  }
}

/// Makes [AppSettings] available to the widget tree and rebuilds on change.
///
/// An inherited notifier rather than a state-management package: one value,
/// read in a handful of places, is not worth a dependency.
class SettingsScope extends InheritedNotifier<AppSettings> {
  const SettingsScope({
    super.key,
    required AppSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static AppSettings of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope?.notifier != null, 'No SettingsScope above this widget');
    return scope!.notifier!;
  }
}
