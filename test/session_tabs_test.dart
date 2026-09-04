// Tests for which channels open a tab, and which merely appear in the list.
//
// The complaint these come from: connecting to a network with five channels
// saved on it opened five tabs and dropped you in whichever one the server
// answered last. That is not what saving a channel meant — being in a room was
// decided once, when the network was set up, and is not a decision to *look*
// at all five of them now.
//
// So the invariant is a distinction, and it is the whole of it: a JOIN for
// ourselves looks identical on the wire whether it came from `/join`, from the
// browser, or from the profile's list being replayed at registration, and only
// the first two are somebody opening something. What separates them is that
// the first two are recorded before the request goes out. If that recording is
// ever lost, this file fails and the tab strip fills up again.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart';

/// A session with no connection behind it. Nothing here calls the core, so
/// nothing here needs the native library.
Future<SessionModel> session() async {
  SharedPreferences.setMockInitialValues({});
  return SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: const ServerConfig(
      host: 'example.test',
      port: 6697,
      nickname: 'me',
      altNicks: [],
      // The saved list, which is what makes the JOINs below the profile's own
      // rather than anybody's decision.
      channels: ['#one', '#two', '#three', '#four', '#five'],
    ),
    settings: await AppSettings.load(),
  );
}

/// The server saying we are now in [channel] — the same event whatever caused
/// it, which is exactly the point.
void joined(SessionModel s, String channel) => s.receiveForTesting(
  IrcEvent.joined(channel: channel, nick: 'me', isSelf: true),
);

List<String> names(List<Conversation> list) =>
    list.map((c) => c.name).toList(growable: false);

void main() {
  // The session coalesces its repaints onto the next frame, so it needs a
  // scheduler even with no widgets anywhere near it.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the profile\'s own channels fill the list, not the strip', () async {
    final s = await session();

    // Five JOINs in a burst, which is what registration looks like on a
    // network with five channels saved.
    for (final channel in ['#one', '#two', '#three', '#four', '#five']) {
      joined(s, channel);
    }

    expect(
      names(s.conversations),
      ['#one', '#two', '#three', '#four', '#five'],
      reason: 'you are in all of them, and the list on the left says so',
    );
    expect(
      names(s.tabs),
      ['#one'],
      reason: 'only the first, so connecting lands somewhere rather than '
          'opening five things nobody asked to see',
    );
    expect(
      s.active?.name,
      '#one',
      reason: 'and the last to arrive must not steal the screen',
    );
  });

  test('a channel the user asked for opens and is selected', () async {
    final s = await session();
    joined(s, '#autojoined');

    // What /join and the browser both do before the request goes out.
    s.requestForTesting('#chosen');
    joined(s, '#chosen');

    expect(names(s.tabs), ['#autojoined', '#chosen']);
    expect(s.active?.name, '#chosen', reason: 'asking for it is asking to be '
        'taken there');
  });

  test('asking is spent once, so a rejoin does not reopen a closed tab', () async {
    final s = await session();
    s.requestForTesting('#chosen');
    joined(s, '#chosen');
    s.closeTab('#chosen');
    expect(names(s.tabs), isEmpty);

    // Cycled by the server — a netsplit healing, a rejoin after a kick. The
    // user asked once, and that ask has already been answered.
    joined(s, '#chosen');
    expect(
      names(s.tabs),
      isEmpty,
      reason: 'a tab the user closed must stay closed',
    );
  });

  test('joining a channel already open just goes there', () async {
    final s = await session();
    joined(s, '#one');
    joined(s, '#two');
    s.select('#one');

    // The browser will happily offer a channel you are sitting in, and the
    // server sends no second JOIN to answer with — so pressing Join there
    // would otherwise be a press that does nothing at all.
    await s.joinChannel('#two');
    expect(s.active?.name, '#two');
  });

  test('a channel someone else joins opens nothing', () async {
    final s = await session();
    joined(s, '#one');

    s.receiveForTesting(
      IrcEvent.joined(channel: '#one', nick: 'alice', isSelf: false),
    );

    expect(names(s.tabs), ['#one']);
    expect(names(s.conversations), ['#one']);
  });

  group('the channel directory', () {
    test('starts empty and is not asked for by itself', () async {
      final s = await session();
      expect(s.directory, isEmpty);
      expect(s.directoryLoading, isFalse);
    });

    test('replaces what it holds rather than appending', () async {
      final s = await session();

      // Two events for one request: each carries the busiest of everything the
      // core has seen, so the earlier one is a prefix of the later. Appending
      // would show every channel twice.
      s.receiveForTesting(
        const IrcEvent.channelList(
          channels: [ChannelListing(name: '#a', users: 10, topic: '')],
          done: false,
          truncated: false,
        ),
      );
      expect(s.directoryLoading, isFalse, reason: 'nothing asked for it yet');

      s.receiveForTesting(
        const IrcEvent.channelList(
          channels: [
            ChannelListing(name: '#a', users: 10, topic: ''),
            ChannelListing(name: '#b', users: 4, topic: 'and another'),
          ],
          done: true,
          truncated: true,
        ),
      );

      expect(s.directory.map((c) => c.name), ['#a', '#b']);
      expect(s.directoryTruncated, isTrue);
    });
  });
}
