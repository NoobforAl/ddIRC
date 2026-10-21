// The XMPP screens under conditions a developer's window never has: a very
// small phone, text turned up to the largest the system allows, a right-to-left
// language, names a hundred characters long, and hundreds of contacts.
//
// A layout bug is an overflow stripe or a thrown exception, and Flutter's test
// binding turns both into a failed test, so each case is "pump it, and nothing
// was thrown". The point is to find, here and cheaply, what would otherwise be
// found on someone's phone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/xmpp_providers.dart';
import 'package:ddirc/src/rust/api/types.dart' as rust;
import 'package:ddirc/src/rust/frb_generated.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/contacts_dialog.dart';
import 'package:ddirc/src/ui/settings/xmpp_provider_dialog.dart';

/// Takes the one call this test makes into the core and does nothing with it.
class _FakeCore implements RustLibApi {
  @override
  Future<void> crateApiClientSetAvailability({
    required BigInt id,
    required rust.Availability availability,
    String? status,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<SessionModel> _session({int contacts = 0, int requests = 0}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await AppSettings.load();
  final s = SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: rust.ServerConfig(
      host: 'example.org',
      port: 5223,
      nickname:
          'a-very-long-account-name-for-a-test@a-very-long-domain.example.org',
      altNicks: const [],
      channels: const [],
    ),
    settings: settings,
    isXmpp: true,
  );
  final long = 'n' * 90;
  for (var i = 0; i < contacts; i++) {
    s.receiveForTesting(
      rust.IrcEvent.contact(
        rust.ContactView(
          jid: i == 0 ? '$long@example.net' : 'user$i@example.net',
          name: i % 3 == 0 ? 'Contact number $i $long' : null,
          subscription: rust.Subscription.values[i % 4],
          asked: i % 5 == 0,
          availability: rust.Availability.values[i % 5],
          status: i % 2 == 0 ? 'status text $i ${'w' * 120}' : '',
        ),
      ),
    );
  }
  for (var i = 0; i < requests; i++) {
    s.receiveForTesting(
      rust.IrcEvent.subscriptionRequest(jid: 'requester$i@example.net'),
    );
  }
  s.dismissNotice();
  return s;
}

/// Pump [child] on a screen of [size] with text at [scale], in [direction].
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(360, 640),
  double scale = 1.0,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: Tokens.themeFor(Tokens.dark),
      builder: (context, app) => Directionality(
        textDirection: direction,
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: app!,
        ),
      ),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeCore()));
  tearDownAll(RustLib.dispose);

  const sizes = {
    'a small phone': Size(320, 568),
    'a normal phone': Size(360, 780),
    'a tablet': Size(900, 1200),
  };
  const scales = [1.0, 2.0];
  const directions = {
    'left to right': TextDirection.ltr,
    'right to left': TextDirection.rtl,
  };

  for (final size in sizes.entries) {
    for (final scale in scales) {
      for (final direction in directions.entries) {
        final where = '${size.key}, text x$scale, ${direction.key}';

        testWidgets('the contact list, many contacts and long names: $where', (
          tester,
        ) async {
          final s = await _session(contacts: 300, requests: 5);
          await _pump(
            tester,
            ContactsDialog(session: s, onOpenChat: (_) {}),
            size: size.value,
            scale: scale,
            direction: direction.value,
          );
          expect(tester.takeException(), isNull);
          // Scroll to the end, where the rows that were not built are.
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -20000),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });

        testWidgets('the contact list, empty: $where', (tester) async {
          final s = await _session();
          await _pump(
            tester,
            ContactsDialog(session: s, onOpenChat: (_) {}),
            size: size.value,
            scale: scale,
            direction: direction.value,
          );
          expect(tester.takeException(), isNull);
        });

        testWidgets('the status dialog: $where', (tester) async {
          final s = await _session();
          await s.setAvailability(
            rust.Availability.dnd,
            status: 'busy ${'b' * 150}',
          );
          await _pump(
            tester,
            StatusDialog(session: s),
            size: size.value,
            scale: scale,
            direction: direction.value,
          );
          expect(tester.takeException(), isNull);
        });

        testWidgets('the list of servers: $where', (tester) async {
          await _pump(
            tester,
            const XmppProviderDialog(),
            size: size.value,
            scale: scale,
            direction: direction.value,
          );
          expect(tester.takeException(), isNull);
          // The list is built lazily, so a row is only there while it is on
          // screen. Scrolled through a screenful at a time, every server has to
          // be seen at some point, and nothing may be thrown on the way.
          final seen = <String>{};
          for (var i = 0; i < 40; i++) {
            for (final p in xmppProviders) {
              if (find.text(p.name).evaluate().isNotEmpty) seen.add(p.name);
            }
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -150),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          expect(seen, xmppProviders.map((p) => p.name).toSet());
        });
      }
    }
  }
}
