import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/notifications.dart';
import 'background_android.dart' show backgroundChannel, hostCallsFor;
import 'notifier.dart';

/// Android, over the channel that already exists.
///
/// No plugin. `MainActivity` is already talking to Dart about the foreground
/// service and already owns the `POST_NOTIFICATIONS` flow, so a message
/// notification is a second channel id and two more methods rather than a
/// dependency — and a dependency would have brought its own notification
/// machinery that knew nothing about the service notification sitting beside
/// it.
///
/// The two are deliberately separate channels on the Android side: the service
/// notice is the price of staying connected and is quiet by design, while a
/// message is the thing the user actually wants. Sharing one channel would
/// mean silencing the price silences the point.
class AndroidNotifier implements Notifier {
  AndroidNotifier({required this.onOpen, this.channel = backgroundChannel});

  final OpenConversation onOpen;

  /// Overridable so a test can watch what is asked of the host without an
  /// Android to ask, exactly as [ForegroundService] does.
  final MethodChannel channel;

  /// Host-to-Dart calls arriving while this is null are dropped rather than
  /// queued. A tap that arrives before the app is listening is a tap on a
  /// notification for a conversation the app has not loaded yet, and guessing
  /// where to go would be worse than going nowhere.
  bool _started = false;

  @override
  Future<void> start() async {
    if (_started) return;
    _started = true;
    // Additive: the background keeper installs its own handler on the same
    // channel, and whichever started second would otherwise silently replace
    // the first. Both go through the one dispatcher.
    hostCallsFor(channel).add(_onHostCall);
  }

  /// Ask for `POST_NOTIFICATIONS`, which from Android 13 is the difference
  /// between a notification and nothing at all.
  ///
  /// This used to be asked for in one place only: turning on *Stay connected
  /// in the background*, because that is what puts a permanent notice in the
  /// shade. Message notifications were never asked about, so on a phone where
  /// that switch had been left alone — its default — every notification this
  /// app raised was dropped by the platform without a word. The switch in
  /// settings said they were on, the code ran end to end, and nothing ever
  /// appeared.
  ///
  /// Two features needing the same permission is not a reason for only one of
  /// them to ask for it.
  @override
  Future<bool> ensurePermitted() async {
    // Below 13 there is no permission and the answer is yes. `true` is also
    // the right answer to a host that could not be reached: refusing to notify
    // because the question failed would turn a channel error into a silent
    // feature loss.
    final allowed = await _ask<bool>('notificationsAllowed') ?? true;
    if (allowed) return true;
    return await _ask<bool>('requestNotifications') ?? false;
  }

  @override
  Future<void> show(NotificationContent content) => _invoke('notifyMessage', {
    'key': content.key,
    'profileId': content.profileId,
    'conversation': content.conversation,
    'title': content.title,
    'body': content.body,
  });

  @override
  Future<void> clear(String key) => _invoke('clearMessage', {'key': key});

  @override
  void dispose() {
    hostCallsFor(channel).remove(_onHostCall);
    _started = false;
  }

  Future<dynamic> _onHostCall(MethodCall call) async {
    if (call.method != 'openConversation') return null;
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    final profileId = arguments['profileId'];
    final conversation = arguments['conversation'];
    if (profileId is String && conversation is String) {
      onOpen(profileId, conversation);
    }
    return null;
  }

  /// Every call to the host in one place, so none of them can bring the app
  /// down. A notification that failed to appear is not worth an exception
  /// reaching the user.
  Future<void> _invoke(String method, Object? arguments) async {
    try {
      await channel.invokeMethod<void>(method, arguments);
    } catch (e) {
      debugPrint('notifications: $method failed ($e)');
    }
  }

  /// The same, for the calls that come back with an answer.
  ///
  /// Null on failure rather than a default, so each caller decides what a
  /// question it could not ask should mean — which is not the same answer
  /// every time.
  Future<T?> _ask<T>(String method) async {
    try {
      return await channel.invokeMethod<T>(method);
    } catch (e) {
      debugPrint('notifications: $method failed ($e)');
      return null;
    }
  }
}
