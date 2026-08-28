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

  @override
  Future<void> show(NotificationContent content) async {}

  @override
  Future<void> clear(String key) async {}

  @override
  void dispose() {}
}
