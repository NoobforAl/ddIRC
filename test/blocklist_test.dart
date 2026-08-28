// Who has been let in, and who has been turned away.
//
// On IRC anyone can message anyone, so a first message from a stranger is a
// request rather than a conversation. Declining one has to mean something, and
// what it means is stored here: a nick that has been refused stays refused
// across a reconnect and across a restart, because a refusal you have to
// repeat every time the app opens is not a refusal.
//
// The nastiest failure available is a block that a rename walks around, which
// is why so much of this file is about case.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<AppSettings> settings() => AppSettings.load();

  group('blocking', () {
    test('nobody is blocked or accepted to begin with', () async {
      final s = await settings();
      expect(s.isBlocked('net', 'alice'), isFalse);
      expect(s.isAccepted('net', 'alice'), isFalse);
      expect(s.blockedFor('net'), isEmpty);
    });

    test('blocking someone sticks, and lists them', () async {
      final s = await settings();
      s.block('net', 'alice');
      expect(s.isBlocked('net', 'alice'), isTrue);
      expect(s.blockedFor('net'), ['alice']);
    });

    test('unblocking lets them back', () async {
      final s = await settings();
      s.block('net', 'alice');
      s.unblock('net', 'alice');
      expect(s.isBlocked('net', 'alice'), isFalse);
      expect(s.blockedFor('net'), isEmpty);
    });

    // The one that matters. IRC nicks are case-insensitive, so a block that
    // `Alice` could step around by capitalising is not a block at all.
    test('case does not get anybody past a block', () async {
      final s = await settings();
      s.block('net', 'Alice');

      for (final spelling in ['alice', 'ALICE', 'AlIcE', 'Alice']) {
        expect(
          s.isBlocked('net', spelling),
          isTrue,
          reason: '$spelling walked around a block on Alice',
        );
      }
      // And unblocking has to fold the same way, or a block could be set by
      // one spelling and never lifted by another.
      s.unblock('net', 'aLiCe');
      expect(s.isBlocked('net', 'Alice'), isFalse);
    });

    // `alice` on Libera and `alice` on a private server are two people, and
    // blocking one must not silence the other.
    test('a block is per network, not per nick', () async {
      final s = await settings();
      s.block('one', 'alice');

      expect(s.isBlocked('one', 'alice'), isTrue);
      expect(s.isBlocked('two', 'alice'), isFalse);
      expect(s.blockedFor('two'), isEmpty);
    });

    test('blocking twice is not two blocks', () async {
      final s = await settings();
      s.block('net', 'alice');
      s.block('net', 'alice');
      expect(s.blockedFor('net'), ['alice']);
    });

    test('the list is sorted, so a name can be found in it', () async {
      final s = await settings();
      for (final nick in ['zoe', 'ada', 'mallory']) {
        s.block('net', nick);
      }
      expect(s.blockedFor('net'), ['ada', 'mallory', 'zoe']);
    });
  });

  group('accepting', () {
    test('accepting is remembered, so nobody is asked about twice', () async {
      final s = await settings();
      s.accept('net', 'alice');
      expect(s.isAccepted('net', 'alice'), isTrue);
    });

    // The two lists answer opposite questions, and an entry in both would be a
    // person who is simultaneously welcome and refused. Each write clears the
    // other rather than leaving the reader to decide which wins.
    test('accepting somebody clears their block', () async {
      final s = await settings();
      s.block('net', 'alice');
      s.accept('net', 'alice');

      expect(s.isAccepted('net', 'alice'), isTrue);
      expect(s.isBlocked('net', 'alice'), isFalse);
      expect(s.blockedFor('net'), isEmpty);
    });

    test('blocking somebody clears their acceptance', () async {
      final s = await settings();
      s.accept('net', 'alice');
      s.block('net', 'alice');

      expect(s.isBlocked('net', 'alice'), isTrue);
      expect(s.isAccepted('net', 'alice'), isFalse);
    });
  });

  group('persistence', () {
    test('a block outlives the app', () async {
      final first = await settings();
      first.block('net', 'Mallory');
      first.accept('net', 'Ada');

      // A second load off the same store is what a restart looks like from
      // here. Being asked again about someone already turned away is the app
      // forgetting, not asking.
      final second = await AppSettings.load();
      expect(second.isBlocked('net', 'mallory'), isTrue);
      expect(second.isAccepted('net', 'ada'), isTrue);
      expect(second.blockedFor('net'), ['mallory']);
    });

    test('an unblock outlives it too', () async {
      final first = await settings();
      first.block('net', 'alice');
      first.unblock('net', 'alice');

      final second = await AppSettings.load();
      expect(second.isBlocked('net', 'alice'), isFalse);
    });
  });

  group('forgetting a profile', () {
    test('takes its blocks and acceptances with it', () async {
      final s = await settings();
      s.block('gone', 'alice');
      s.accept('gone', 'bob');
      s.block('kept', 'mallory');

      await s.forgetProfile('gone');

      expect(s.isBlocked('gone', 'alice'), isFalse);
      expect(s.isAccepted('gone', 'bob'), isFalse);
      // A profile deleted and recreated under a new id would otherwise leave
      // its block list behind as an invisible reason messages go missing.
      expect(s.blockedFor('gone'), isEmpty);
      expect(s.isBlocked('kept', 'mallory'), isTrue);
    });

    test('and the notification levels, as it always did', () async {
      final s = await settings();
      s.setNotifyFor('gone', '#chat', NotifyLevel.none);
      s.block('gone', 'alice');

      await s.forgetProfile('gone');
      expect(s.notifyFor('gone', '#chat'), NotifyLevel.all);
    });

    test('forgetting a profile with nothing stored is not an error', () async {
      final s = await settings();
      await s.forgetProfile('never-used');
      expect(s.blockedFor('never-used'), isEmpty);
    });
  });
}
