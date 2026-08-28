// Tests for being told about a message while ddIRC is not the thing in front.
//
// Almost none of this feature can be observed where it happens. A toast on
// Windows is drawn by the operating system, an Android notification by the
// system UI, and neither exists in a widget test — so what is tested is
// everything that *decides*: whether the app counts as in front, whether a
// line is worth interrupting someone for, what the notification is allowed to
// say, and, on Android, the exact conversation held with the host.
//
// That split is deliberate in the code too: `model/notifications.dart` has no
// Flutter in it at all, precisely so this file can exist.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/notifications.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/ui/background_android.dart' show hostCallsFor;
import 'package:ddirc/src/ui/notifier.dart';
import 'package:ddirc/src/ui/notifier_android.dart';
import 'package:ddirc/src/ui/presence.dart';

/// The ordinary case: a direct message, app in the background, nothing muted.
///
/// Named parameters override one fact at a time, so each test below reads as
/// the single thing it is about rather than as nine arguments.
bool notify({
  bool enabled = true,
  bool appInForeground = false,
  bool conversationActive = false,
  bool isChannel = false,
  bool isMention = false,
  bool isSelf = false,
  bool isSystem = false,
  bool pending = false,
  NotifyLevel level = NotifyLevel.all,
}) => shouldNotify(
  enabled: enabled,
  appInForeground: appInForeground,
  conversationActive: conversationActive,
  isChannel: isChannel,
  isMention: isMention,
  isSelf: isSelf,
  isSystem: isSystem,
  pending: pending,
  level: level,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('whether the app is in front', () {
    test('a paused app is never in front, focused or not', () {
      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.inactive,
        AppLifecycleState.detached,
        AppLifecycleState.hidden,
      ]) {
        expect(isInForeground(state, windowFocused: true), isFalse);
        expect(isInForeground(state), isFalse);
      }
    });

    // The whole reason this file exists. A desktop window sitting behind a
    // browser is still `resumed` — the app has not been backgrounded in any
    // sense the framework recognises — so asking only the lifecycle would
    // report the app as in front for most of the time it plainly is not.
    test('a resumed but unfocused window is not in front', () {
      expect(
        isInForeground(AppLifecycleState.resumed, windowFocused: false),
        isFalse,
      );
    });

    test('resumed and focused is in front', () {
      expect(
        isInForeground(AppLifecycleState.resumed, windowFocused: true),
        isTrue,
      );
    });

    // Android has no window to focus, and null means the question does not
    // apply rather than that the answer is no.
    test('where there is no window, resumed is enough', () {
      expect(isInForeground(AppLifecycleState.resumed), isTrue);
    });

    test('AppPresence follows both, and only says so when it changes', () {
      final presence = AppPresence(watchesWindow: true);
      var changes = 0;
      presence.addListener(() => changes++);

      expect(presence.inForeground, isTrue, reason: 'launched in front');

      presence.setForTesting(focused: false);
      expect(presence.inForeground, isFalse);
      expect(changes, 1);

      // Already out of front; being paused as well is not news.
      presence.setForTesting(state: AppLifecycleState.paused);
      expect(changes, 1);

      presence.setForTesting(state: AppLifecycleState.resumed, focused: true);
      expect(presence.inForeground, isTrue);
      expect(changes, 2);

      presence.dispose();
    });
  });

  group('what is worth interrupting someone for', () {
    test('a direct message, while the app is away', () {
      expect(notify(), isTrue);
    });

    test('never our own message, and never a join or a part', () {
      expect(notify(isSelf: true), isFalse);
      expect(notify(isSystem: true), isFalse);
    });

    test('never what is already on the screen being looked at', () {
      expect(notify(appInForeground: true, conversationActive: true), isFalse);
    });

    // In front, but reading something else. The message still needs surfacing:
    // a direct message that arrives in a conversation you are not looking at
    // is exactly as missable as one that arrives while the app is minimised.
    test('but a different conversation in a foreground app still counts', () {
      expect(notify(appInForeground: true), isTrue);
    });

    test('a conversation in the background is not "already read"', () {
      expect(notify(conversationActive: true), isTrue);
    });

    // The single decision that keeps notifications worth leaving on.
    test('a channel only when it names us', () {
      expect(notify(isChannel: true), isFalse);
      expect(notify(isChannel: true, isMention: true), isTrue);
    });

    test('the master switch silences everything', () {
      expect(notify(enabled: false), isFalse);
      expect(notify(enabled: false, pending: true), isFalse);
      expect(notify(enabled: false, isChannel: true, isMention: true), isFalse);
    });
  });

  group('the per-conversation level is a ceiling, not a floor', () {
    test('muted means muted, even for a direct message', () {
      expect(notify(level: NotifyLevel.none), isFalse);
      expect(notify(level: NotifyLevel.none, pending: true), isFalse);
    });

    test('mentions-only narrows a channel and leaves a DM alone', () {
      expect(notify(level: NotifyLevel.mentions, isChannel: true), isFalse);
      expect(
        notify(level: NotifyLevel.mentions, isChannel: true, isMention: true),
        isTrue,
      );
      // A direct message was addressed to this person and nobody else, which
      // is a stronger claim on their attention than a nick in a crowded room.
      expect(notify(level: NotifyLevel.mentions), isTrue);
    });

    // The trap the enum's name sets. `all` is every conversation's default and
    // means "count every message in the badge" — it must not be read as
    // "interrupt me for every message", or turning nothing on would make every
    // channel shout.
    test('the default level does not promote a channel to shouting', () {
      expect(notify(level: NotifyLevel.all, isChannel: true), isFalse);
    });
  });

  group('a request from a stranger', () {
    test('is its own reason to interrupt, even in a channel-shaped rule', () {
      expect(notify(pending: true), isTrue);
    });

    test('says who, and never what they said', () {
      final content = buildNotification(
        profileId: 'p1',
        networkLabel: 'Libera.Chat',
        conversation: 'mallory',
        sender: 'mallory',
        isChannel: false,
        isAction: false,
        pending: true,
        text: 'click this link',
        preview: true,
      );

      // Previews on, and it still refuses. Showing what a stranger said before
      // the user has agreed to hear from them would defeat the point of
      // asking — it is how an unsolicited message gets read anyway.
      expect(content.body, 'wants to message you');
      expect(content.body, isNot(contains('link')));
      expect(content.title, 'mallory — Libera.Chat');
    });
  });

  group('what the notification says', () {
    test('sender only, by default', () {
      final dm = buildNotification(
        profileId: 'p1',
        networkLabel: 'Libera.Chat',
        conversation: 'ada',
        sender: 'ada',
        isChannel: false,
        isAction: false,
        pending: false,
        text: 'the meeting moved to four',
        preview: false,
      );

      expect(dm.title, 'ada — Libera.Chat');
      expect(dm.body, 'sent you a message');
      expect(dm.body, isNot(contains('meeting')));
    });

    test('a channel mention names the channel', () {
      final mention = buildNotification(
        profileId: 'p1',
        networkLabel: 'Libera.Chat',
        conversation: '#chat',
        sender: 'ada',
        isChannel: true,
        isAction: false,
        pending: false,
        text: 'noobforal: are you there',
        preview: false,
      );

      expect(mention.title, 'ada in #chat — Libera.Chat');
      expect(mention.body, 'mentioned you');
    });

    test('with the preview on, it carries the text', () {
      final dm = buildNotification(
        profileId: 'p1',
        networkLabel: 'Libera.Chat',
        conversation: 'ada',
        sender: 'ada',
        isChannel: false,
        isAction: false,
        pending: false,
        text: 'the meeting moved to four',
        preview: true,
      );

      expect(dm.body, 'the meeting moved to four');
    });

    test('an action reads as one', () {
      final action = buildNotification(
        profileId: 'p1',
        networkLabel: 'Libera.Chat',
        conversation: 'ada',
        sender: 'ada',
        isChannel: false,
        isAction: true,
        pending: false,
        text: 'waves',
        preview: true,
      );

      expect(action.body, 'ada waves');
    });

    // A notification is one string on every platform, and a stray newline
    // renders as a gap or as nothing at all depending on who is drawing it.
    test('newlines and runs of space are flattened', () {
      final content = buildNotification(
        profileId: 'p1',
        networkLabel: 'net',
        conversation: 'ada',
        sender: 'ada',
        isChannel: false,
        isAction: false,
        pending: false,
        text: '  hello\n\n  there  ',
        preview: true,
      );

      expect(content.body, 'hello there');
    });

    test('a long message is cut, and says that it was', () {
      final content = buildNotification(
        profileId: 'p1',
        networkLabel: 'net',
        conversation: 'ada',
        sender: 'ada',
        isChannel: false,
        isAction: false,
        pending: false,
        text: 'x' * 500,
        preview: true,
      );

      expect(content.body.length, notificationPreviewLimit);
      expect(content.body, endsWith('…'));
    });
  });

  group('the key that identifies a conversation', () {
    // A second message from the same person should replace the first rather
    // than stacking. Ten toasts saying alice is talking to you is not ten
    // times the information.
    test('is stable for the same conversation', () {
      String keyFor(String conversation) => buildNotification(
        profileId: 'p1',
        networkLabel: 'net',
        conversation: conversation,
        sender: 'ada',
        isChannel: false,
        isAction: false,
        pending: false,
        text: 'hello',
        preview: false,
      ).key;

      expect(keyFor('ada'), keyFor('Ada'));
      expect(keyFor('ada'), isNot(keyFor('grace')));
    });

    test('separates the same nick on two networks', () {
      expect(
        NotificationContent.keyFor('one', 'ada'),
        isNot(NotificationContent.keyFor('two', 'ada')),
      );
    });

    test('matches what clearing one will ask for', () {
      final content = buildNotification(
        profileId: 'p1',
        networkLabel: 'net',
        conversation: 'Ada',
        sender: 'Ada',
        isChannel: false,
        isAction: false,
        pending: false,
        text: 'hello',
        preview: false,
      );
      expect(content.key, NotificationContent.keyFor('p1', 'ada'));
    });
  });

  group('which platforms are offered this', () {
    test('the desktops and Android, never iOS', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.android,
      ]) {
        expect(notificationsSupportedOn(platform), isTrue);
      }
      expect(notificationsSupportedOn(TargetPlatform.iOS), isFalse);
    });

    test('a notifier that cannot notify is still a notifier', () async {
      // Rather than a null everything above would have to remember about.
      const notifier = NoNotifier();
      await notifier.start();
      await notifier.show(
        const NotificationContent(
          profileId: 'p',
          conversation: 'c',
          title: 't',
          body: 'b',
        ),
      );
      await notifier.clear('p/c');
      notifier.dispose();
    });
  });

  // The Android half is testable in a way the desktop half is not, because it
  // speaks over a MethodChannel and a MethodChannel can be listened to. So it
  // is tested properly: the calls, their arguments, and the way back.
  group('the conversation with the Android host', () {
    late List<MethodCall> calls;
    late MethodChannel channel;
    late AndroidNotifier notifier;
    late List<(String, String)> opened;

    final binding = TestWidgetsFlutterBinding.ensureInitialized();

    setUp(() {
      calls = [];
      opened = [];
      channel = const MethodChannel('dev.ddirc/background.notify.test');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) {
        calls.add(call);
        return null;
      });
      notifier = AndroidNotifier(
        onOpen: (profileId, conversation) =>
            opened.add((profileId, conversation)),
        channel: channel,
      );
    });

    tearDown(() {
      notifier.dispose();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('showing one hands over everything the host has to draw', () async {
      await notifier.start();
      await notifier.show(
        const NotificationContent(
          profileId: 'p1',
          conversation: 'ada',
          title: 'ada — Libera.Chat',
          body: 'sent you a message',
        ),
      );

      expect(calls.single.method, 'notifyMessage');
      expect(calls.single.arguments, {
        'key': 'p1/ada',
        'profileId': 'p1',
        'conversation': 'ada',
        'title': 'ada — Libera.Chat',
        'body': 'sent you a message',
      });
    });

    test('clearing one names it by the same key', () async {
      await notifier.start();
      await notifier.clear('p1/ada');

      expect(calls.single.method, 'clearMessage');
      expect(calls.single.arguments, {'key': 'p1/ada'});
    });

    test('a tap comes back with where to go', () async {
      await notifier.start();

      // What MainActivity sends when a notification is tapped.
      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('openConversation', {
            'profileId': 'p1',
            'conversation': '#chat',
          }),
        ),
        (_) {},
      );
      await pumpEventQueue();

      expect(opened, [('p1', '#chat')]);
    });

    test('a call that is not ours is left alone', () async {
      await notifier.start();

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall('quit')),
        (_) {},
      );
      await pumpEventQueue();

      expect(opened, isEmpty);
    });

    // Both the notifier and the background keeper want to hear from the host
    // on this one channel. A MethodChannel has exactly one handler, so
    // whichever registered second used to silently replace the first — a bug
    // that would look like one feature working perfectly until the other was
    // switched on.
    test('two listeners on one channel both hear it', () async {
      await notifier.start();

      final alsoHeard = <String>[];
      Future<dynamic> second(MethodCall call) async {
        alsoHeard.add(call.method);
        return null;
      }

      hostCallsFor(channel).add(second);
      addTearDown(() => hostCallsFor(channel).remove(second));

      await binding.defaultBinaryMessenger.handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          const MethodCall('openConversation', {
            'profileId': 'p1',
            'conversation': 'ada',
          }),
        ),
        (_) {},
      );
      await pumpEventQueue();

      expect(opened, [('p1', 'ada')]);
      expect(alsoHeard, ['openConversation']);
    });

    test('a failing host does not bring the app down', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => throw PlatformException(code: 'boom'),
      );
      await notifier.start();

      // Not being notified is a feature missing. It must never be an app
      // crashing, and never a connection lost.
      await notifier.show(
        const NotificationContent(
          profileId: 'p1',
          conversation: 'ada',
          title: 't',
          body: 'b',
        ),
      );
      await notifier.clear('p1/ada');
    });
  });
}
