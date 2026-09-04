import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
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
  static const _kNotifications = 'app.notifications';
  static const _kNotifyPreview = 'app.notifyPreview';
  static const _kNotifyPrefix = 'notify.';
  static const _kShowMembers = 'ui.showMembers';

  /// People whose first message was declined, and people whose was accepted.
  ///
  /// Two lists rather than one tri-state, because they answer different
  /// questions in different places: blocked is consulted on every incoming
  /// direct message, accepted only on the first one from a nick with no
  /// conversation yet. Both are keyed `<profileId>/<nick>` with the nick folded
  /// to lower case — IRC nicks are case-insensitive, and a block that `Alice`
  /// walks around is not a block.
  static const _kBlockedPrefix = 'blocked.';
  static const _kAcceptedPrefix = 'accepted.';

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

  /// On, unlike [_runInBackground] next to it, and the difference is worth
  /// stating. That setting changes what closing a window means, which is a
  /// promise about the app's lifetime; this one only decides whether a message
  /// you would already have wanted reaches you a moment sooner. It stores
  /// nothing, and what it is allowed to say is deliberately narrow — a direct
  /// message or your nickname, never ambient channel traffic.
  bool _notifications = true;

  /// Off, because this is the half that leaks.
  ///
  /// A notification is drawn by the operating system and may sit on a lock
  /// screen, which puts the text somewhere this app can no longer take it back
  /// from. Who is asking for you is enough to decide whether to look; what they
  /// said is a choice to make deliberately.
  bool _notifyPreview = false;

  /// Off, so a wide window shows the conversation and not the roster.
  ///
  /// The member list used to appear the moment the window was wide enough,
  /// which made it a property of the window rather than a thing anyone asked
  /// for: on a desktop it was simply always there, taking 190 points to list
  /// people who are mostly not saying anything. It is one press away in the
  /// header, and the count of who is present stays on that button either way —
  /// which is the part of it that is worth having at a glance.
  bool _showMembers = false;

  Density _density = Density.comfortable;
  ThemeMode _themeMode = ThemeMode.dark;
  final Map<String, NotifyLevel> _notify = {};
  final Set<String> _blocked = {};
  final Set<String> _accepted = {};

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
    _notifications = prefs.getBool(_kNotifications) ?? _notifications;
    _notifyPreview = prefs.getBool(_kNotifyPreview) ?? _notifyPreview;
    _showMembers = prefs.getBool(_kShowMembers) ?? _showMembers;
    _density = Density.values.firstWhere(
      (d) => d.name == prefs.getString(_kDensity),
      orElse: () => _density,
    );
    _themeMode = ThemeMode.values.firstWhere(
      (m) => m.name == prefs.getString(_kThemeMode),
      orElse: () => _themeMode,
    );
    // One pass over the keys for all three prefixed maps. Each is stored as one
    // key per entry rather than as an encoded list, so a write touches only the
    // thing that changed and a corrupt entry costs one nick rather than all of
    // them.
    for (final key in prefs.getKeys()) {
      if (key.startsWith(_kNotifyPrefix)) {
        final level = NotifyLevel.values.firstWhere(
          (l) => l.name == prefs.getString(key),
          orElse: () => NotifyLevel.all,
        );
        _notify[key.substring(_kNotifyPrefix.length)] = level;
      } else if (key.startsWith(_kBlockedPrefix)) {
        _blocked.add(key.substring(_kBlockedPrefix.length));
      } else if (key.startsWith(_kAcceptedPrefix)) {
        _accepted.add(key.substring(_kAcceptedPrefix.length));
      }
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
  bool get notifications => _notifications;
  bool get notifyPreview => _notifyPreview;
  bool get showMembers => _showMembers;
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

  set notifications(bool value) => _set(_kNotifications, value, () {
    _notifications = value;
  });

  set notifyPreview(bool value) => _set(_kNotifyPreview, value, () {
    _notifyPreview = value;
  });

  set showMembers(bool value) => _set(_kShowMembers, value, () {
    _showMembers = value;
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

  /// Whether messages from [nick] on this network are dropped unread.
  ///
  /// Set by declining someone's first message. Consulted on every incoming
  /// direct message, so it has to be a set lookup and not a scan.
  bool isBlocked(String profileId, String nick) =>
      _blocked.contains(_scopedKey(profileId, nick));

  /// Whether [nick] has already been let in, so a later message from them is a
  /// conversation rather than another request.
  ///
  /// Kept separately from the conversation itself because conversations do not
  /// survive a reconnect and this answer has to: being asked again about
  /// someone you already accepted is the app forgetting, not asking.
  bool isAccepted(String profileId, String nick) =>
      _accepted.contains(_scopedKey(profileId, nick));

  /// The nicks blocked on one network, in the order they read best — sorted,
  /// because a list nobody can find a name in is not a list they can undo.
  List<String> blockedFor(String profileId) {
    final prefix = '$profileId/';
    final nicks = [
      for (final key in _blocked)
        if (key.startsWith(prefix)) key.substring(prefix.length),
    ];
    nicks.sort();
    return nicks;
  }

  /// Decline someone. Blocking also un-accepts, so the two can never disagree.
  void block(String profileId, String nick) {
    final key = _scopedKey(profileId, nick);
    if (!_blocked.add(key)) return;
    _prefs?.setBool('$_kBlockedPrefix$key', true);
    if (_accepted.remove(key)) _prefs?.remove('$_kAcceptedPrefix$key');
    notifyListeners();
  }

  void unblock(String profileId, String nick) {
    final key = _scopedKey(profileId, nick);
    if (!_blocked.remove(key)) return;
    _prefs?.remove('$_kBlockedPrefix$key');
    notifyListeners();
  }

  /// Let someone in. Accepting also unblocks, for the same reason.
  void accept(String profileId, String nick) {
    final key = _scopedKey(profileId, nick);
    if (!_accepted.add(key)) return;
    _prefs?.setBool('$_kAcceptedPrefix$key', true);
    if (_blocked.remove(key)) _prefs?.remove('$_kBlockedPrefix$key');
    notifyListeners();
  }

  /// Drop everything belonging to a deleted profile: notification levels, and
  /// who was let in or turned away.
  ///
  /// All three together, because they are all scoped by the same profile and a
  /// profile deleted and recreated under a new id would otherwise leave its
  /// block list behind as an invisible reason messages go missing.
  Future<void> forgetProfile(String profileId) async {
    final prefix = '$profileId/';
    var changed = false;

    final levels = _notify.keys.where((k) => k.startsWith(prefix)).toList();
    for (final key in levels) {
      _notify.remove(key);
      await _prefs?.remove('$_kNotifyPrefix$key');
      changed = true;
    }

    for (final (set, storePrefix) in [
      (_blocked, _kBlockedPrefix),
      (_accepted, _kAcceptedPrefix),
    ]) {
      final gone = set.where((k) => k.startsWith(prefix)).toList();
      for (final key in gone) {
        set.remove(key);
        await _prefs?.remove('$storePrefix$key');
        changed = true;
      }
    }

    if (changed) notifyListeners();
  }

  static String _notifyKey(String profileId, String conversation) =>
      _scopedKey(profileId, conversation);

  /// Everything scoped to one network is keyed the same way, folded to lower
  /// case: channels because IRC treats `#Foo` and `#foo` as one room, nicks
  /// because it treats `Alice` and `alice` as one person.
  static String _scopedKey(String profileId, String name) =>
      '$profileId/${name.toLowerCase()}';

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

/// Where the settings file is, for showing in the settings screen.
///
/// `shared_preferences` has always written a file; what it has never done is
/// say where, which made "are my settings saved?" a question with no answer
/// short of going and looking. On desktop it is one JSON file in the app's own
/// data directory, beside the logs.
///
/// Android is deliberately vaguer, because a path there would be a lie of
/// precision: the store is an XML file under `/data/data/<package>/shared_prefs`
/// that no file manager can open and no user can act on. Saying it is private
/// to the app is the true and useful answer.
///
/// Never throws. A settings screen must not fail to open because a path could
/// not be resolved.
Future<String> settingsFileLocation() async {
  if (!kIsWeb && Platform.isAndroid) {
    return 'Private to the app, managed by Android';
  }
  try {
    final base = await getApplicationSupportDirectory();
    return '${base.path}${Platform.pathSeparator}shared_preferences.json';
  } catch (e) {
    debugPrint('could not resolve the settings location: $e');
    return 'Unavailable on this platform';
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
