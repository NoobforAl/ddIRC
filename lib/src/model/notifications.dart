// What is worth interrupting someone for, and what it is allowed to say.
//
// Deliberately free of Flutter, of plugins and of platforms. Everything here
// is a decision, and a decision that can only be observed by watching a toast
// appear on Windows is a decision nobody can test. Raising the notification is
// somebody else's job — `ui/notifier.dart` — and it does none of this thinking.

import 'settings.dart';

/// One notification, already decided and already worded.
class NotificationContent {
  const NotificationContent({
    required this.profileId,
    required this.conversation,
    required this.title,
    required this.body,
  });

  /// Which network and which conversation it came from, so that clicking it
  /// can land somewhere and reading the conversation can take it away again.
  final String profileId;
  final String conversation;

  final String title;
  final String body;

  /// Identifies this conversation's notification across platforms.
  ///
  /// The same conversation always produces the same key, so a second message
  /// replaces the first rather than stacking. Ten toasts saying the same person
  /// is talking to you is not ten times the information.
  String get key => keyFor(profileId, conversation);

  /// The key for a conversation, without a notification to hand.
  ///
  /// Needed for taking one away: at that point all that is known is which
  /// conversation was opened, not what was once said in it.
  static String keyFor(String profileId, String conversation) =>
      '$profileId/${conversation.toLowerCase()}';

  @override
  String toString() => 'NotificationContent($key, $title, $body)';
}

/// Whether this line is worth taking someone away from what they are doing.
///
/// The rule, in order:
///
/// - **Never our own messages, never system lines.** Joins and parts are not
///   news, and being notified of your own message is absurd.
/// - **Never what is already on screen.** If the app is in front and this is
///   the conversation being looked at, the message has already arrived in the
///   only way that matters.
/// - **A direct message always; a channel only on a mention.** Every line of
///   every channel is what makes people turn notifications off altogether, and
///   a notification nobody has turned off is worth more than one that says
///   everything.
///
/// [level] is a **ceiling, not a floor**, and the enum's name invites the
/// opposite reading. `NotifyLevel.all` is what a conversation is set to by
/// default, and it means "count every message in the badge" — it does not mean
/// "interrupt me for every message". Badges and interruptions are different
/// loudnesses of the same question, and only `none` and `mentions` carry over,
/// as ways of asking for less.
bool shouldNotify({
  required bool enabled,
  required bool appInForeground,
  required bool conversationActive,
  required bool isChannel,
  required bool isMention,
  required bool isSelf,
  required bool isSystem,
  required bool pending,
  required NotifyLevel level,
}) {
  if (!enabled) return false;
  if (isSelf || isSystem) return false;
  if (appInForeground && conversationActive) return false;

  switch (level) {
    case NotifyLevel.none:
      return false;
    case NotifyLevel.mentions:
      // A direct message is a mention by construction: it was addressed to
      // this person and nobody else, which is a stronger claim on their
      // attention than their nick appearing in a room full of people.
      if (isChannel && !isMention) return false;
    case NotifyLevel.all:
      break;
  }

  // A request is its own reason. Something the user has not decided about yet
  // is the one case where silence would mean the decision never gets made.
  if (pending) return true;

  return !isChannel || isMention;
}

/// The longest message preview a notification will carry.
///
/// Not a display concern — every platform truncates for itself, and better.
/// This is about how much of a conversation ends up somewhere the app cannot
/// take it back from, such as a lock screen, if the preview is ever turned on.
const notificationPreviewLimit = 140;

/// Word the notification.
///
/// [preview] is the setting, and it is off by default. With it off this says
/// only *who* wants attention and *where* — enough to decide whether to look,
/// and nothing that would be a leak if the phone were face up on a table.
NotificationContent buildNotification({
  required String profileId,
  required String networkLabel,
  required String conversation,
  required String sender,
  required bool isChannel,
  required bool isAction,
  required bool pending,
  required String text,
  required bool preview,
}) {
  // The title names the person, because that is what the eye goes to, with the
  // network after it — `alice` on two networks is two people, and a toast that
  // does not say which one leaves the wrong one to be opened.
  final title = isChannel
      ? '$sender in $conversation — $networkLabel'
      : '$sender — $networkLabel';

  final String body;
  if (pending) {
    // Stated even when previews are on. This is not a message to read, it is a
    // question to answer, and showing what a stranger said before the user has
    // agreed to hear from them would defeat the point of asking.
    body = 'wants to message you';
  } else if (preview) {
    body = isAction ? '$sender ${_clip(text)}' : _clip(text);
  } else if (isChannel) {
    body = 'mentioned you';
  } else {
    body = 'sent you a message';
  }

  return NotificationContent(
    profileId: profileId,
    conversation: conversation,
    title: title,
    body: body,
  );
}

/// Collapse the line and cut it, with an ellipsis if anything was lost.
///
/// Newlines go first: the core already splits a message into one line per
/// `PRIVMSG`, but a notification is one string on every platform and a stray
/// break renders as a gap or as nothing at all depending on who is drawing it.
String _clip(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= notificationPreviewLimit) return flat;
  return '${flat.substring(0, notificationPreviewLimit - 1).trimRight()}…';
}
