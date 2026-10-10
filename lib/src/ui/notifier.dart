import 'package:flutter/foundation.dart';

import '../model/notifications.dart';
import 'notifier_android.dart';
import 'notifier_desktop.dart';

/// Where tapping a notification should land.
///
/// A callback rather than a reference to the workspace, because raising a
/// notification and knowing how to navigate are different jobs and only one of
/// them is platform-specific.
typedef OpenConversation = void Function(String profileId, String conversation);

/// Whether [platform] can show a notification about a message.
///
/// The same three desktops plus Android as [runsInBackgroundOn], and for once
/// that is a coincidence worth not collapsing: this asks whether the operating
/// system will draw a notification for us, that one asks whether the process
/// survives losing its window. iOS fails both, for unrelated reasons.
bool notificationsSupportedOn(TargetPlatform platform) => const {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
  TargetPlatform.android,
}.contains(platform);

/// Where to go when notifications are on here and still not appearing.
///
/// Every platform has a switch above this app's, ddIRC cannot read any of
/// them, and all of them fail the same silent way: the toast is simply never
/// drawn. Naming the actual screen is the whole value of this — "check your
/// system settings" is advice nobody has ever been helped by.
String notificationHelpFor(TargetPlatform platform) => switch (platform) {
  TargetPlatform.windows =>
    'Windows has its own switch above this one. If nothing appears, open '
        'Settings → System → Notifications and check that notifications are '
        'on, that ddIRC is allowed, and that Do not disturb is off.',
  TargetPlatform.macOS =>
    'macOS has its own switch above this one. If nothing appears, open '
        'System Settings → Notifications → ddIRC and allow them there, and '
        'check that Focus is off.',
  TargetPlatform.android =>
    'Android asks for permission the first time this is switched on. If '
        'nothing appears, or the permission was refused, it can be given '
        'again in the system Settings → Apps → ddIRC → Notifications.',
  TargetPlatform.linux =>
    'Your desktop has its own notification settings above this one, and its '
        'own do-not-disturb. If nothing appears, that is where to look.',
  _ => 'This platform will not show notifications.',
};

/// A switch above this app's own that is dropping its notifications.
///
/// [notificationHelpFor] says where such switches live; this says which one is
/// actually off, on the platforms that will answer. Both exist because the
/// failure they describe is silent — the system drops what it forbids without
/// a word to the app, and the settings page goes on saying notifications are
/// on.
enum NotificationBlock {
  /// Windows' own "Get notifications from apps and other senders", which
  /// silences every app at once.
  allApps,

  /// Every notification from ddIRC, switched off in the system settings. On
  /// Android 13 and later this is also what a refused permission looks like.
  app,

  /// Android's *Messages* category alone. The connection notice still shows,
  /// so from the outside this looks like notifications working.
  messages;

  /// What is off, and that it is not this app's switch — said plainly enough
  /// that the button beside it is obviously the fix.
  String get explanation => switch (this) {
    NotificationBlock.allApps =>
      'Windows has notifications from apps switched off, for every app, so '
          'nothing this switch allows can appear.',
    NotificationBlock.app =>
      'Notifications for ddIRC are switched off in the system settings, so '
          'nothing this switch allows can appear.',
    NotificationBlock.messages =>
      'The Messages notification category is switched off in the system '
          'settings, so nothing this switch allows can appear.',
  };
}

/// Which system switch is blocking notifications, or null for none that this
/// platform will admit to.
///
/// Null is also the answer to a question that could not be asked. A note
/// claiming notifications are blocked when they are not would be worse than
/// the silence this exists to break.
Future<NotificationBlock?> notificationBlock() async {
  if (kIsWeb) return null;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => androidNotificationBlock(),
    TargetPlatform.windows => windowsNotificationBlock(),
    _ => null,
  };
}

/// Open the system screen where a [NotificationBlock] is undone.
Future<void> openSystemNotificationSettings() async {
  if (kIsWeb) return;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      await openAndroidNotificationSettings();
    case TargetPlatform.windows:
      await openWindowsNotificationSettings();
    default:
      break;
  }
}

/// Raises notifications, and takes them away again.
///
/// Shaped like [BackgroundKeeper] on purpose — an interface, a factory that is
/// the only place the platform is decided, and implementations that never
/// check again — because the two solve the same shape of problem: one promise,
/// two platforms, no shared mechanism whatsoever.
abstract interface class Notifier {
  /// Prepare whatever the platform needs before the first notification. Safe to
  /// call once, at startup.
  Future<void> start();

  /// Ask the platform for permission to show notifications, if it has one to
  /// give, and report whether it will now show them.
  ///
  /// Separate from [start] because the two answer different questions and one
  /// of them is the user's. Registering with the platform is bookkeeping and
  /// happens whatever the settings say; *asking* is an interruption, and is
  /// only worth making when the user has notifications switched on — which is
  /// something only the caller knows.
  ///
  /// Called again whenever that switch is turned on, so a refusal is never
  /// permanent: Android will show its dialog again the next time, and a user
  /// who has refused twice can still be told plainly what is wrong.
  Future<bool> ensurePermitted();

  /// Show one, replacing any earlier one for the same conversation.
  Future<void> show(NotificationContent content);

  /// Take away the notification for one conversation, by
  /// [NotificationContent.key]. Called when the conversation is read, so that
  /// looking at a message on one screen does not leave it demanding attention
  /// on another.
  Future<void> clear(String key);

  void dispose();
}

/// The right [Notifier] for this platform, or one that does nothing.
Notifier notifierFor({required OpenConversation onOpen}) {
  if (kIsWeb || !notificationsSupportedOn(defaultTargetPlatform)) {
    return const NoNotifier();
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => AndroidNotifier(onOpen: onOpen),
    _ => DesktopNotifier(onOpen: onOpen),
  };
}

/// iOS, and anywhere else that cannot honestly offer this.
///
/// A real object rather than a null, so nothing above has to remember that
/// this is sometimes absent — the same reason [NoBackgroundKeeper] exists.
class NoNotifier implements Notifier {
  const NoNotifier();

  @override
  Future<void> start() async {}

  /// False, and honestly so. This platform will not show one, and a caller
  /// that wants to say why is entitled to a straight answer rather than an
  /// optimistic one from an object that does nothing.
  @override
  Future<bool> ensurePermitted() async => false;

  @override
  Future<void> show(NotificationContent content) async {}

  @override
  Future<void> clear(String key) async {}

  @override
  void dispose() {}
}
