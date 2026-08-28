import 'dart:async';

import 'package:flutter/foundation.dart';

import '../model/notifications.dart';
import '../model/profile.dart';
import '../model/session.dart';
import '../model/settings.dart';
import 'notifier.dart';
import 'presence.dart';

/// Joins up the four things a notification needs, none of which know about each
/// other.
///
/// [SessionModel] knows a message arrived and where. [AppPresence] knows
/// whether anyone was looking. [shouldNotify] and [buildNotification] know
/// whether it is worth saying and how to say it. [Notifier] knows how to say it
/// on this platform. This is the only place all four meet, which is why it is
/// the only place that has to change when any of them does.
class NotificationRouter {
  NotificationRouter({
    required this.settings,
    required this.profiles,
    required this.presence,
    required this.notifier,
  });

  final AppSettings settings;

  /// Read for the network's name, which is what the user calls it rather than
  /// what the server calls itself.
  final ProfileStore profiles;

  final AppPresence presence;
  final Notifier notifier;

  /// Conversations with a notification currently on screen.
  ///
  /// Tracked so that clearing one is cheap and, more to the point, so that
  /// clearing one that was never raised does not reach the platform at all —
  /// every conversation opened would otherwise be a channel call.
  final Set<String> _showing = {};

  Future<void> start() => notifier.start();

  void dispose() {
    notifier.dispose();
    _showing.clear();
  }

  /// A line arrived. Decide, word it, and raise it — or do nothing, which is
  /// the answer most of the time and has to be the cheap one.
  void onLine(SessionModel session, Conversation conversation, ChatLine line) {
    final message = line.message;
    if (message == null) return;

    if (!shouldNotify(
      enabled: settings.notifications,
      appInForeground: presence.inForeground,
      conversationActive: identical(session.active, conversation),
      isChannel: conversation.isChannel,
      isMention: line.isMention,
      isSelf: line.isSelf,
      isSystem: line.isSystem,
      pending: conversation.pending,
      level: settings.notifyFor(session.profileId, conversation.name),
    )) {
      return;
    }

    final content = buildNotification(
      profileId: session.profileId,
      networkLabel: _labelFor(session),
      conversation: conversation.name,
      sender: message.sender,
      isChannel: conversation.isChannel,
      isAction: message.isAction,
      pending: conversation.pending,
      text: message.spans.map((s) => s.text).join(),
      preview: settings.notifyPreview,
    );

    _showing.add(content.key);
    unawaited(notifier.show(content));
  }

  /// A conversation was opened, so anything still asking about it should stop.
  void onRead(SessionModel session, Conversation conversation) {
    final key = NotificationContent.keyFor(
      session.profileId,
      conversation.name,
    );
    if (!_showing.remove(key)) return;
    unawaited(notifier.clear(key));
  }

  /// What to call the network in a notification.
  ///
  /// The saved profile's name first, because that is what the user typed and
  /// what they will recognise. The network's own announced name is the fallback
  /// for a profile saved without one, and the host is the last resort — never
  /// nothing, because `alice` on two networks is two people and a toast that
  /// does not say which is a toast that opens the wrong window.
  String _labelFor(SessionModel session) {
    final profile = profiles.byId(session.profileId);
    final name = profile?.name.trim();
    if (name != null && name.isNotEmpty) return name;
    return session.network ?? session.config.host;
  }
}

/// Everything a notification needs, built and started together.
///
/// A small holder rather than four fields threaded through the app: the pieces
/// are useless apart, and `main` should be able to say "notifications" once.
class Notifications {
  Notifications._(this.presence, this.router);

  final AppPresence presence;
  final NotificationRouter router;

  /// [onOpen] is where a tapped notification lands, which only the app above
  /// knows how to do.
  factory Notifications.create({
    required AppSettings settings,
    required ProfileStore profiles,
    required OpenConversation onOpen,
  }) {
    final presence = AppPresence();
    return Notifications._(
      presence,
      NotificationRouter(
        settings: settings,
        profiles: profiles,
        presence: presence,
        notifier: notifierFor(onOpen: onOpen),
      ),
    );
  }

  Future<void> start() async {
    presence.start();
    try {
      await router.start();
    } catch (e) {
      // Never fatal. Not being notified is a feature missing; a failure here
      // reaching the user would be the app refusing to run because a toast
      // could not be registered.
      debugPrint('notifications could not start: $e');
    }
  }

  void dispose() {
    router.dispose();
    presence.dispose();
  }
}
