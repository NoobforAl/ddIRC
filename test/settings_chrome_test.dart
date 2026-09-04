// Tests for the pieces of chrome that hide something.
//
// They all exist to shorten a dialog that had grown unreadable, and they all
// take the same risk in doing it: a setting that is no longer on screen is a
// setting the user can believe is not set. So the invariant worth pinning is
// not that they fold — it is that folding never conceals an answer. A nav row
// carries a summary of what is inside it; a disclosure shows its summary while
// shut and can be opened from outside, which is what a validation error inside
// one has to be able to do; a '?' gives back the whole paragraph it replaced,
// unabridged, on one press.
//
// The eye on a secret field is the same bargain read the other way. There the
// default is the hiding one and the press is what stops it — but it is still
// the user who decides, and still one press either way.

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

  group('the help dot', () {
    const explanation = 'Every network goes through it, with no exceptions.';

    testWidgets('a switch keeps its explanation until it is asked for', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SettingsSwitch(
            label: 'Route everything through Tor',
            description: explanation,
            value: false,
            onChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The label is the whole row until someone wants more.
      expect(find.text('Route everything through Tor'), findsOneWidget);
      expect(find.text(explanation), findsNothing);

      await tester.tap(find.byType(HelpDot));
      await tester.pumpAndSettle();

      // Given back in full, not summarised. That is the promise of the dot.
      expect(find.text(explanation), findsOneWidget);

      await tester.tap(find.byType(HelpDot));
      await tester.pumpAndSettle();
      expect(find.text(explanation), findsNothing);
    });

    testWidgets('asking what a switch does never flips it', (tester) async {
      var changed = 0;
      await tester.pumpWidget(
        _host(
          SettingsSwitch(
            label: 'Save chat logs',
            description: explanation,
            value: false,
            onChanged: (_) => changed++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The dot sits inside the row's own tap target, so this is the case
      // worth pinning: the innermost recogniser has to win, or reading about
      // a setting would be the same gesture as changing it.
      await tester.tap(find.byType(HelpDot));
      await tester.pumpAndSettle();

      expect(changed, 0);
      expect(find.text(explanation), findsOneWidget);
    });

    testWidgets('a row with nothing to explain grows no dot', (tester) async {
      await tester.pumpWidget(
        _host(
          SettingsSwitch(
            label: '24-hour clock',
            value: true,
            onChanged: (_) {},
          ),
        ),
      );

      expect(find.byType(HelpDot), findsNothing);
    });

    testWidgets('a section heading can carry one for the whole feature', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const SettingsSection(
            label: 'Local server',
            help: explanation,
            children: [SettingsReadout(label: 'Status', value: 'Running')],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The readouts are never hidden by the dot — only the prose is.
      expect(find.text('Running'), findsOneWidget);
      expect(find.text(explanation), findsNothing);

      await tester.tap(find.byType(HelpDot));
      await tester.pumpAndSettle();
      expect(find.text(explanation), findsOneWidget);
    });

    testWidgets('a labelled field can explain where what is typed ends up', (
      tester,
    ) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(
          SettingsLabelledField(
            label: 'SASL password',
            controller: controller,
            help: explanation,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(explanation), findsNothing);
      await tester.tap(find.byType(HelpDot));
      await tester.pumpAndSettle();
      expect(find.text(explanation), findsOneWidget);
    });

    testWidgets('a dot never knocks the field beside it out of line', (
      tester,
    ) async {
      final left = TextEditingController();
      final right = TextEditingController();
      addTearDown(left.dispose);
      addTearDown(right.dispose);

      await tester.pumpWidget(
        _host(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: SettingsLabelledField(
                  label: 'Address',
                  controller: left,
                  help: explanation,
                ),
              ),
              Expanded(
                child: SettingsLabelledField(label: 'Port', controller: right),
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Address and Port sit side by side and only one of them has anything to
      // explain. The label row is a fixed height for exactly this: a taller
      // label on one side would drop that side's box below the other's.
      final boxes = tester.widgetList<TextField>(find.byType(TextField));
      expect(boxes.length, 2);
      final tops = find
          .byType(TextField)
          .evaluate()
          .map((e) => tester.getTopLeft(find.byWidget(e.widget)).dy);
      expect(tops.toSet().length, 1);
    });
  });

  group('a secret field', () {
    Future<TextField> field(WidgetTester tester) async =>
        tester.widget<TextField>(find.byType(TextField));

    testWidgets('starts hidden and shows itself on request', (tester) async {
      final controller = TextEditingController(text: 'hunter2');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(SettingsField(controller: controller, obscure: true)),
      );

      // Hidden is the default and stays the default: the eye is an escape
      // hatch for checking a password, not a preference.
      expect((await field(tester)).obscureText, isTrue);

      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();
      expect((await field(tester)).obscureText, isFalse);

      // And the icon now reports the state it is in, so it can be pressed
      // back.
      await tester.tap(find.byIcon(Icons.visibility_outlined));
      await tester.pumpAndSettle();
      expect((await field(tester)).obscureText, isTrue);
    });

    testWidgets('an ordinary field has no eye to press', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_host(SettingsField(controller: controller)));

      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
      expect((await field(tester)).obscureText, isFalse);
    });

    testWidgets('a revealed field goes back to dots when it is rebuilt as an '
        'ordinary one', (tester) async {
      final controller = TextEditingController(text: 'hunter2');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        _host(SettingsField(controller: controller, obscure: true)),
      );
      await tester.tap(find.byIcon(Icons.visibility_off_outlined));
      await tester.pumpAndSettle();
      expect((await field(tester)).obscureText, isFalse);

      // The same slot in the tree, no longer a secret and then a secret again.
      // Without the reset it would come back already showing.
      await tester.pumpWidget(_host(SettingsField(controller: controller)));
      await tester.pumpWidget(
        _host(SettingsField(controller: controller, obscure: true)),
      );
      await tester.pumpAndSettle();

      expect((await field(tester)).obscureText, isTrue);
    });
  });
}
