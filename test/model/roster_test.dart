// Tests for keeping a channel's member list current.
//
// The bug these exist to prevent came back the same way twice in principle:
// the core knew who was in a channel, the UI held a list, and nothing carried
// one to the other except a full roster sent at two moments. So the list on
// screen was correct when you walked into `#Debian` and never again — 883
// people, none of whom could ever be shown arriving or leaving.
//
// The fix is a delta, which puts an ordering question on this side of the FFI
// for the first time: inserting one nick means knowing where it goes. That is
// what `sortKey` answers, and what most of this file is about — the order has
// to come out the same as the order the core would have sorted, or a roster
// drifts out of shape one arrival at a time.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/rust/api/types.dart';

/// A member as the core would send one.
///
/// The key is the core's own: a fixed-width privilege rank, a separator below
/// every printable character, then the nick folded. Built here rather than
/// stubbed, because a test that invents its own ordering proves nothing about
/// the one that ships.
MemberView _member(String nick, {String? prefix, bool away = false}) {
  const ranks = {'@': 2, '+': 4};
  final rank = ranks[prefix] ?? 0xffff;
  return MemberView(
    nick: nick,
    prefix: prefix,
    away: away,
    sortKey:
        '${rank.toRadixString(16).padLeft(4, '0')}'
        '${nick.toLowerCase()}',
  );
}

Conversation _channel(List<MemberView> members) =>
    Conversation(name: '#test', isChannel: true)..members = members;

List<String> _nicks(Conversation c) => [for (final m in c.members) m.nick];

void main() {
  group('applying one change to a roster', () {
    test(
      'an arrival lands in the position the core would have sorted it to',
      () {
        final channel = _channel([
          _member('alice', prefix: '@'),
          _member('bob'),
          _member('dave'),
        ]);

        channel.applyMemberChange('carol', _member('carol'));

        // Between bob and dave, not appended: a list that grows at the end is
        // sorted only until the first person joins.
        expect(_nicks(channel), ['alice', 'bob', 'carol', 'dave']);
      },
    );

    test('an arrival with privileges goes above everyone without them', () {
      final channel = _channel([_member('alice'), _member('bob')]);

      channel.applyMemberChange('zoe', _member('zoe', prefix: '@'));

      expect(_nicks(channel), ['zoe', 'alice', 'bob']);
    });

    test('a departure removes exactly the row it names', () {
      final channel = _channel([
        _member('alice'),
        _member('bob'),
        _member('carol'),
      ]);

      channel.applyMemberChange('bob', null);

      expect(_nicks(channel), ['alice', 'carol']);
    });

    test('a rename moves the row rather than leaving both spellings', () {
      final channel = _channel([
        _member('alice'),
        _member('bob'),
        _member('carol'),
      ]);

      channel.applyMemberChange('alice', _member('zoe'));

      // The old nick is gone and the new one is in its own place, which is not
      // where the old one was. A rename that only relabelled would leave the
      // list out of order.
      expect(_nicks(channel), ['bob', 'carol', 'zoe']);
    });

    test('being opped moves someone up the list in one event', () {
      final channel = _channel([
        _member('alice'),
        _member('bob'),
        _member('carol'),
      ]);

      channel.applyMemberChange('carol', _member('carol', prefix: '@'));

      expect(_nicks(channel), ['carol', 'alice', 'bob']);
      expect(channel.members.first.prefix, '@');
    });

    test('going away changes the row in place', () {
      final channel = _channel([_member('alice'), _member('bob')]);

      channel.applyMemberChange('bob', _member('bob', away: true));

      expect(_nicks(channel), ['alice', 'bob']);
      expect(channel.members[1].away, isTrue);
    });

    test('a nick spelled differently on the wire still finds its row', () {
      final channel = _channel([_member('Alice'), _member('bob')]);

      // Nicks are case-insensitive on IRC, so `ALICE` leaving is `Alice`
      // leaving. Failing to match would leave a ghost in the list and let a
      // duplicate in behind it.
      channel.applyMemberChange('ALICE', null);

      expect(_nicks(channel), ['bob']);
    });

    test('a departure for someone not here changes nothing', () {
      final channel = _channel([_member('alice')]);

      channel.applyMemberChange('nobody', null);

      expect(_nicks(channel), ['alice']);
    });

    test('the list is replaced rather than mutated', () {
      final channel = _channel([_member('alice')]);
      final before = channel.members;

      channel.applyMemberChange('bob', _member('bob'));

      // `MemberList` compares list identity to decide whether to look for
      // arrivals at all — that is what stops it hashing every nick in the
      // channel on a repaint caused by another one. Mutating in place would
      // leave it looking at a list it believes it has already seen, and the
      // arrival would never fade in.
      expect(identical(before, channel.members), isFalse);
      expect(before.length, 1, reason: 'the old list is left as it was');
    });

    test('many arrivals in any order end up in one order', () {
      final channel = _channel([]);
      for (final nick in ['zoe', 'alice', 'Bob', 'carol', 'dave']) {
        channel.applyMemberChange(nick, _member(nick));
      }

      // Case-insensitive, so `Bob` sorts among the lowercase names rather
      // than above all of them the way a plain string sort would put it.
      expect(_nicks(channel), ['alice', 'Bob', 'carol', 'dave', 'zoe']);
    });
  });
}
