import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';

import '../model/notifications.dart';
import 'notifier.dart';

/// Windows, macOS and Linux, through whatever each of them calls a toast.
///
/// One notification is kept per conversation and reused. Two things depend on
/// that: a second message from the same person replaces the first rather than
/// stacking a pile of near-identical toasts, and reading the conversation has
/// something to close. It also matters for a reason that is easy to miss —
/// `LocalNotification` adds itself to the plugin's listener list the moment it
/// is constructed, so building a fresh one per message would leak a listener
/// per message for the lifetime of the app.
class DesktopNotifier implements Notifier {
  DesktopNotifier({required this.onOpen});

  final OpenConversation onOpen;

  final Map<String, LocalNotification> _live = {};
  bool _ready = false;

  /// Register with the platform.
  ///
  /// On Windows a toast is delivered on behalf of an Application User Model ID,
  /// and an AUMID has to belong to a Start Menu shortcut — the operating system
  /// will not show a notification for an application it cannot name. The
  /// installer creates that shortcut; [ShortcutPolicy.requireCreate] covers
  /// running from a build directory, where nothing installed anything.
  ///
  /// A failure here is not fatal and must not be: not being notified is worse
  /// than being notified, and both are far better than an app that will not
  /// start because it could not register a toast.
  @override
  Future<void> start() async {
    try {
      await localNotifier.setup(
        appName: 'ddIRC',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      _ready = true;
    } catch (e) {
      debugPrint('notifications unavailable: $e');
    }
  }

  @override
  Future<void> show(NotificationContent content) async {
    if (!_ready) return;
    await clear(content.key);

    final notification = LocalNotification(
      identifier: content.key,
      title: content.title,
      body: content.body,
    )..onClick = () => onOpen(content.profileId, content.conversation);
    // Clicked or dismissed, it is gone from the screen either way, and a map
    // entry for a notification that no longer exists would stop the next
    // message from showing one.
    notification.onClose = (_) => _forget(content.key);

    _live[content.key] = notification;
    try {
      await notification.show();
    } catch (e) {
      debugPrint('could not show a notification: $e');
      _forget(content.key);
    }
  }

  @override
  Future<void> clear(String key) async {
    final existing = _live.remove(key);
    if (existing == null) return;
    try {
      await existing.close();
    } catch (e) {
      debugPrint('could not close a notification: $e');
    } finally {
      localNotifier.removeListener(existing);
    }
  }

  @override
  void dispose() {
    for (final notification in _live.values) {
      localNotifier.removeListener(notification);
    }
    _live.clear();
  }

  void _forget(String key) {
    final gone = _live.remove(key);
    if (gone != null) localNotifier.removeListener(gone);
  }
}
