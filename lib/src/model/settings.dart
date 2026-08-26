import 'package:flutter/material.dart';
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

/// Display names for Flutter's own [ThemeMode], so the settings UI can render
/// it the same way it renders [Density] and [NotifyLevel].
extension ThemeModeLabel on ThemeMode {
  String get label => switch (this) {
    ThemeMode.system => 'System',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };
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
  static const _kThemeMode = 'ui.themeMode';
  static const _kColors = 'ui.mircColors';
  static const _kChatLog = 'log.chat';
  static const _kDebugLog = 'log.debug';
  static const _kStripMetadata = 'send.stripMetadata';
  static const _kFileTransfers = 'dcc.enabled';
  static const _kRunInBackground = 'app.runInBackground';
  static const _kNotifyPrefix = 'notify.';

  final SharedPreferences? _prefs;

  bool _fileTransfers = false;
  bool _showTimestamps = true;
  bool _twentyFourHour = true;
  bool _showSystemMessages = true;
  bool _renderColors = true;

  /// Both off, and both stay off until asked for. A chat log is the most
  /// sensitive file the app can write, and a debug log is dead weight to
  /// anyone who is not chasing a bug.
  bool _saveChatLogs = false;
  bool _saveDebugLogs = false;

  /// On, unlike everything else here that touches privacy.
  ///
  /// The other switches decide whether to *keep* something the user already
  /// has. This one decides whether to hand a stranger the coordinates of the
  /// room a photograph was taken in, and a default that has to be found before
  /// it protects anyone is not a protection.
  bool _stripImageMetadata = true;

  /// Off, because closing a window and having the app keep running is not what
  /// closing a window means anywhere else. It has to be asked for, and the
  /// first time it happens it must be something the user chose rather than
  /// something they discover by finding the app still connected an hour later.
  bool _runInBackground = false;
  Density _density = Density.comfortable;
  ThemeMode _themeMode = ThemeMode.dark;
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
    _saveChatLogs = prefs.getBool(_kChatLog) ?? _saveChatLogs;
    _saveDebugLogs = prefs.getBool(_kDebugLog) ?? _saveDebugLogs;
    _stripImageMetadata = prefs.getBool(_kStripMetadata) ?? _stripImageMetadata;
    _fileTransfers = prefs.getBool(_kFileTransfers) ?? _fileTransfers;
    _runInBackground = prefs.getBool(_kRunInBackground) ?? _runInBackground;
    _density = Density.values.firstWhere(
      (d) => d.name == prefs.getString(_kDensity),
      orElse: () => _density,
    );
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == prefs.getString(_kThemeMode),
      orElse: () => _themeMode,
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
  bool get saveChatLogs => _saveChatLogs;
  bool get saveDebugLogs => _saveDebugLogs;
  bool get stripImageMetadata => _stripImageMetadata;
  bool get runInBackground => _runInBackground;
  Density get density => _density;
  ThemeMode get themeMode => _themeMode;

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

  set saveChatLogs(bool value) => _set(_kChatLog, value, () {
    _saveChatLogs = value;
  });

  set saveDebugLogs(bool value) => _set(_kDebugLog, value, () {
    _saveDebugLogs = value;
  });

  /// Whether DCC file transfers are offered at all — beta.
  ///
  /// Off, and it takes more than a switch to turn on: the section that owns
  /// it puts the risk in words and waits for an answer first. That is not
  /// ceremony. Every other setting here decides how the app looks or what it
  /// writes to its own disk; this one decides whether a stranger's message can
  /// result in a TCP connection between their machine and this one, and
  /// whether your address is handed to whoever asks for a file.
  ///
  /// While it is off, an offer is not shown at all. A notice that something
  /// was offered and cannot be accepted is a prompt to go and turn this on,
  /// which is the opposite of what an off switch should do.
  bool get fileTransfers => _fileTransfers;

  set fileTransfers(bool value) => _set(_kFileTransfers, value, () {
    _fileTransfers = value;
  });

  set stripImageMetadata(bool value) => _set(_kStripMetadata, value, () {
    _stripImageMetadata = value;
  });

  set runInBackground(bool value) => _set(_kRunInBackground, value, () {
    _runInBackground = value;
  });

  set density(Density value) => _set(_kDensity, value.name, () {
    _density = value;
  });

  set themeMode(ThemeMode value) => _set(_kThemeMode, value.name, () {
    _themeMode = value;
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
