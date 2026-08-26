// Tests for the two pieces of chrome that hide settings.
//
// Both exist to shorten a dialog that had grown unreadable, and both take the
// same risk in doing it: a setting that is no longer on screen is a setting
// the user can believe is not set. So the invariant worth pinning is not that
// they fold — it is that folding never conceals an answer. A nav row carries a
// summary of what is inside it; a disclosure shows its summary while shut and
// can be opened from outside, which is what a validation error inside one has
// to be able to do.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/settings_chrome.dart';

Widget _host(Widget child) => MaterialApp(
  theme: Tokens.themeFor(Tokens.dark),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  group('SettingsNavRow', () {
    testWidgets('shows what is set inside it, not only its name', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SettingsNavRow(
            label: 'Connection',
            summary: 'Built-in Tor · local server on',
            onTap: () {},
          ),
        ),
      );

      expect(find.text('Connection'), findsOneWidget);
      expect(find.text('Built-in Tor · local server on'), findsOneWidget);
    });

    testWidgets('opens on a tap', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _host(
          SettingsNavRow(
            label: 'Privacy',
            summary: 'Nothing written to disk',
            onTap: () => opened++,
          ),
        ),
      );

      await tester.tap(find.text('Privacy'));
      expect(opened, 1);
    });

    testWidgets('carries the beta badge when what is inside is beta', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SettingsNavRow(
            label: 'Connection',
            summary: 'Direct',
            beta: true,
            onTap: () {},
          ),
        ),
      );

      // On the row rather than only inside the page, because the point of the
      // badge is to be seen before the feature is reached.
      expect(find.byType(BetaBadge), findsOneWidget);
    });
  });

  group('SettingsDisclosure', () {
    Widget disclosure({required bool open, VoidCallback? onToggle}) => _host(
      SettingsDisclosure(
        label: 'Advanced',
        summary: 'SASL · own proxy',
        open: open,
        onToggle: onToggle ?? () {},
        children: const [
          SettingsReadout(label: 'Inside', value: 'a folded setting'),
        ],
      ),
    );

    testWidgets('shut, it names what it is holding and shows none of it', (
      tester,
    ) async {
      await tester.pumpWidget(disclosure(open: false));
      await tester.pumpAndSettle();

      expect(find.text('SASL · own proxy'), findsOneWidget);
      expect(find.text('a folded setting'), findsNothing);
    });

    testWidgets('open, the contents are there and the summary is not', (
      tester,
    ) async {
      await tester.pumpWidget(disclosure(open: true));
      await tester.pumpAndSettle();

      expect(find.text('a folded setting'), findsOneWidget);
      // Repeating the summary above the thing it summarises is noise.
      expect(find.text('SASL · own proxy'), findsNothing);
    });

    testWidgets('asks its caller to open rather than opening itself', (
      tester,
    ) async {
      var toggled = 0;
      await tester.pumpWidget(
        disclosure(open: false, onToggle: () => toggled++),
      );

      await tester.tap(find.text('Advanced'));
      await tester.pumpAndSettle();

      expect(toggled, 1);
      // Still shut: the caller holds the state. That is what lets a form open
      // this from the outside when it finds an error inside it.
      expect(find.text('a folded setting'), findsNothing);
    });
  });
}
