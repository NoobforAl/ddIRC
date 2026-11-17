// Tests for the shipped network catalogue and the picker over it.
//
// Two different kinds of thing are being protected here.
//
// The catalogue is data, and the failures it can have are the ones nobody
// notices: a plaintext port on a client that only speaks TLS, a hostname
// duplicated between two entries so one of them can never be resolved back,
// a channel written without its `#`. None of those look wrong in a list —
// they look wrong at connect time, to the user, once.
//
// The picker is a flow, and what matters there is that the answer it returns
// is the answer that was on screen: the channels ticked, in the order the
// catalogue lists them, and nothing that was left unticked.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/directory.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/network_picker_dialog.dart';

void main() {
  group('the catalogue', () {
    test('is not empty, and every entry can actually be dialled', () {
      expect(knownNetworks, isNotEmpty);
      for (final network in knownNetworks) {
        expect(network.name.trim(), isNotEmpty, reason: network.host);
        expect(network.host.trim(), isNotEmpty, reason: network.name);
        expect(network.blurb.trim(), isNotEmpty, reason: network.name);
        // The app makes no unencrypted connections, so an entry on a
        // plaintext port is an entry that can only ever fail.
        expect(
          network.port,
          greaterThan(0),
          reason: '${network.name} needs a port',
        );
        expect(
          network.port,
          isNot(6667),
          reason: '${network.name} is on the plaintext port',
        );
        // A host with a port stuck on it would be resolved as a hostname and
        // fail with a DNS error that names nothing useful.
        expect(
          network.host,
          isNot(contains(':')),
          reason: '${network.name} has a port in its host',
        );
      }
    });

    test('has no two entries on the same host', () {
      // knownNetworkFor answers with the first match, so a duplicate would be
      // an entry the app could never resolve back to.
      final hosts = knownNetworks.map((n) => n.host.toLowerCase()).toList();
      expect(hosts.toSet().length, hosts.length);
    });

    test('writes every channel the way it would be typed', () {
      for (final network in knownNetworks) {
        for (final channel in network.channels) {
          expect(
            channel.name,
            startsWith('#'),
            reason: '${network.name} ${channel.name}',
          );
          expect(
            channel.name,
            isNot(contains(' ')),
            reason: '${network.name} ${channel.name}',
          );
          expect(
            channel.blurb.trim(),
            isNotEmpty,
            reason: '${network.name} ${channel.name}',
          );
        }
        // The first channel of every network is the one the picker ticks by
        // default, so it has to be the one to ask questions in rather than
        // whichever happened to be listed first.
        final names = network.channels.map((c) => c.name).toList();
        expect(names.toSet().length, names.length, reason: network.name);
      }
    });

    test('says something extra about the networks that need it', () {
      // Not a style rule: these three are the entries where connecting
      // without knowing the caveat is a bad afternoon. EFnet keeps nothing
      // for you, OFTC will not take a SASL password, and IRCnet's TLS is not
      // on the address every guide gives you.
      for (final name in ['EFnet', 'OFTC', 'IRCnet']) {
        final network = knownNetworks.firstWhere((n) => n.name == name);
        expect(network.note, isNotNull, reason: name);
      }
    });
  });

  group('looking a network up by host', () {
    test('finds one however it was typed', () {
      expect(knownNetworkFor('irc.libera.chat')?.name, 'Libera.Chat');
      expect(knownNetworkFor('IRC.Libera.Chat')?.name, 'Libera.Chat');
      // Typed into a form, so it arrives with whatever whitespace came with
      // the paste.
      expect(knownNetworkFor('  irc.oftc.net  ')?.name, 'OFTC');
    });

    test('does not guess', () {
      expect(knownNetworkFor(''), isNull);
      expect(knownNetworkFor('irc.example.org'), isNull);
      // A near miss is still a miss: suggesting Libera's channels on
      // somebody's private server would be worse than suggesting nothing.
      expect(knownNetworkFor('libera.chat'), isNull);
    });
  });

  group('search', () {
    test('with nothing typed is the whole list', () {
      expect(searchNetworks('').length, knownNetworks.length);
      expect(searchNetworks('   ').length, knownNetworks.length);
    });

    test('finds a network by name or address', () {
      expect(searchNetworks('rizon').single.name, 'Rizon');
      expect(searchNetworks('oftc.net').single.name, 'OFTC');
    });

    test('finds a network by a channel on it', () {
      // The point of the search box: knowing where Debian talks is exactly
      // what someone new does not know.
      expect(searchNetworks('debian').single.name, 'OFTC');
      expect(searchNetworks('#archlinux').single.name, 'Libera.Chat');
    });

    test('returns nothing rather than everything when nothing matches', () {
      expect(searchNetworks('zzzzz'), isEmpty);
    });
  });

  group('editing a channel list', () {
    test('reads a field however it was punctuated', () {
      expect(parseChannels('#a, #b'), ['#a', '#b']);
      expect(parseChannels('  #a ,,  #b  , '), ['#a', '#b']);
      expect(parseChannels(''), isEmpty);
      expect(parseChannels('   '), isEmpty);
    });

    test('adds a channel that is not there and removes one that is', () {
      expect(toggleChannel(const ['#a'], '#b'), ['#a', '#b']);
      expect(toggleChannel(const ['#a', '#b'], '#a'), ['#b']);
    });

    test('treats a channel as one channel whatever its case', () {
      // IRC does. Adding #debian beside a hand-typed #Debian would join the
      // same room twice and show it twice in the strip.
      expect(toggleChannel(const ['#Debian'], '#debian'), isEmpty);
    });

    test('leaves every other entry exactly as the user wrote it', () {
      final before = ['#Keep-This', '#drop'];
      expect(toggleChannel(before, '#drop'), ['#Keep-This']);
      // And does not edit the list it was handed.
      expect(before, ['#Keep-This', '#drop']);
    });
  });

  group('the picker', () {
    testWidgets('lists the networks, and opens one', (tester) async {
      await _open(tester);
      expect(find.text('Libera.Chat'), findsOneWidget);
      expect(find.text('OFTC'), findsOneWidget);

      await tester.tap(find.text('OFTC'));
      await tester.pumpAndSettle();

      // The channel step, and the caveat that comes with this network.
      expect(find.text('#debian'), findsOneWidget);
      expect(find.textContaining('CertFP'), findsOneWidget);
    });

    testWidgets('narrows to what was searched for', (tester) async {
      await _open(tester);
      await tester.enterText(find.byType(TextField).first, 'debian');
      await tester.pumpAndSettle();

      expect(find.text('OFTC'), findsOneWidget);
      expect(find.text('Libera.Chat'), findsNothing);
    });

    testWidgets('starts with somewhere to ask ticked, and nothing else', (
      tester,
    ) async {
      final result = await _open(tester);
      await tester.tap(find.text('Libera.Chat'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue with 1'));
      await tester.pumpAndSettle();

      expect(result()!.channels, ['#libera']);
    });

    testWidgets('returns what was ticked, in catalogue order', (tester) async {
      final result = await _open(tester);
      await tester.tap(find.text('Libera.Chat'));
      await tester.pumpAndSettle();

      // Tapped out of order on purpose: the autojoin list should read like
      // the list the user was looking at, not like their tap history.
      await tester.tap(find.text('#rust'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#python'));
      await tester.pumpAndSettle();
      // And off again, to prove a tick is a toggle rather than an add.
      await tester.tap(find.text('#libera'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue with 2'));
      await tester.pumpAndSettle();

      final pick = result()!;
      expect(pick.network.name, 'Libera.Chat');
      expect(pick.channels, ['#python', '#rust']);
    });

    testWidgets('goes back to the list without keeping the ticks', (
      tester,
    ) async {
      await _open(tester);
      await tester.tap(find.text('Libera.Chat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#rust'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('OFTC'), findsOneWidget);

      await tester.tap(find.text('Libera.Chat'));
      await tester.pumpAndSettle();
      // Opening a network is a fresh choice, not a resumed one.
      expect(find.text('Continue with 1'), findsOneWidget);
    });
  });
}

/// Open the picker over an otherwise empty app.
///
/// Returns a getter for what the dialog eventually popped with, so a test can
/// drive the flow and then read the answer.
Future<NetworkPick? Function()> _open(WidgetTester tester) async {
  NetworkPick? picked;

  // Taller than the default 600pt test window. The dialog scrolls, and a
  // network with a dozen channels puts its buttons below the fold — which
  // would make these tests about scroll offsets rather than about the flow.
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                picked = await NetworkPickerDialog.show(context);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  return () => picked;
}
