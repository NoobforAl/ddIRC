// Tests for the message composer.
//
// What is worth pinning is not the pixels but the promises the shape makes:
// that it is one surface rather than a field with an outline, that the send
// button is a button that is always there (so the field never changes width
// under the cursor), and that sending still works every way it used to.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/composer.dart';

Widget _host(Widget child, {ThemeMode mode = ThemeMode.dark}) => MaterialApp(
  theme: Tokens.themeFor(Tokens.light),
  darkTheme: Tokens.themeFor(Tokens.dark),
  themeMode: mode,
  home: Scaffold(
    body: Align(alignment: Alignment.bottomCenter, child: child),
  ),
);

Composer _composer({
  required TextEditingController controller,
  required FocusNode focus,
  VoidCallback? onSubmit,
  VoidCallback? onAttach,
}) => Composer(
  controller: controller,
  focusNode: focus,
  hint: 'Message #rust',
  onSubmit: onSubmit ?? () {},
  onAttach: onAttach,
);

IconButton _sendButton(WidgetTester tester) => tester.widget<IconButton>(
  find.widgetWithIcon(IconButton, Icons.arrow_upward_rounded),
);

void main() {
  late TextEditingController controller;
  late FocusNode focus;

  setUp(() {
    controller = TextEditingController();
    focus = FocusNode();
  });
  tearDown(() {
    controller.dispose();
    focus.dispose();
  });

  testWidgets('says where a message will go, and has no outline to light up', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_composer(controller: controller, focus: focus)),
    );

    expect(find.text('Message #rust'), findsOneWidget);

    // One surface, not a field with a border: every state's border is none,
    // and the field itself is not filled (the container behind it is).
    final field = tester.widget<TextField>(find.byType(TextField));
    final d = field.decoration!;
    for (final border in [
      d.border,
      d.enabledBorder,
      d.focusedBorder,
      d.disabledBorder,
      d.errorBorder,
      d.focusedErrorBorder,
    ]) {
      expect(border, InputBorder.none);
    }
    expect(d.filled, isFalse);

    // And it keeps the one TextField the rest of the app finds it by.
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('sits in a rounded surface the colour of a message bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_composer(controller: controller, focus: focus)),
    );

    final surface = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((b) => b.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.color == Tokens.dark.bubble);
    expect(surface, isNotEmpty);
    // Fully rounded ends: half the one-line height.
    expect(
      surface.first.borderRadius,
      BorderRadius.circular(22),
      reason: 'the ends are round, as a messenger bar is',
    );
  });

  testWidgets('the send button is quiet until there is something to send', (
    tester,
  ) async {
    var sent = 0;
    await tester.pumpWidget(
      _host(
        _composer(controller: controller, focus: focus, onSubmit: () => sent++),
      ),
    );

    expect(_sendButton(tester).onPressed, isNull, reason: 'nothing to send');

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNotNull);

    await tester.tap(find.byTooltip('Send'));
    expect(sent, 1);

    // Spaces are not a message.
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pumpAndSettle();
    expect(_sendButton(tester).onPressed, isNull);
  });

  testWidgets('the keyboard\'s send action sends too', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      _host(
        _composer(controller: controller, focus: focus, onSubmit: () => sent++),
      ),
    );

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    expect(sent, 1);
  });

  testWidgets('the field does not change width when the first letter arrives', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_composer(controller: controller, focus: focus)),
    );
    final empty = tester.getSize(find.byType(TextField)).width;

    await tester.enterText(find.byType(TextField), 'h');
    await tester.pumpAndSettle();

    // The button is always there, so typing reflows nothing.
    expect(tester.getSize(find.byType(TextField)).width, empty);
  });

  testWidgets('the paperclip is inside the bar, and only when there is a file '
      'to send', (tester) async {
    var attached = 0;
    await tester.pumpWidget(
      _host(_composer(controller: controller, focus: focus)),
    );
    expect(find.byTooltip('Send a file'), findsNothing);

    await tester.pumpWidget(
      _host(
        _composer(
          controller: controller,
          focus: focus,
          onAttach: () => attached++,
        ),
      ),
    );
    expect(find.byTooltip('Send a file'), findsOneWidget);
    await tester.tap(find.byTooltip('Send a file'));
    expect(attached, 1);

    // Inside the surface: to the left of the send button, level with the field.
    final clip = tester.getRect(find.byTooltip('Send a file'));
    final send = tester.getRect(find.byTooltip('Send'));
    final field = tester.getRect(find.byType(TextField));
    expect(clip.right, lessThanOrEqualTo(send.left));
    expect(clip.left, greaterThanOrEqualTo(field.right - 1));
  });

  testWidgets('grows with what is typed, up to five lines, and keeps its '
      'buttons beside the last one', (tester) async {
    await tester.pumpWidget(
      _host(_composer(controller: controller, focus: focus, onAttach: () {})),
    );
    final one = tester.getSize(find.byType(TextField)).height;

    await tester.enterText(find.byType(TextField), 'a\nb\nc');
    await tester.pumpAndSettle();
    final three = tester.getSize(find.byType(TextField)).height;
    expect(three, greaterThan(one));

    await tester.enterText(
      find.byType(TextField),
      List.filled(20, 'x').join('\n'),
    );
    await tester.pumpAndSettle();
    final many = tester.getSize(find.byType(TextField)).height;
    expect(many, lessThan(one * 6), reason: 'capped, not unbounded');

    // The send button stays level with the bottom of the field.
    final send = tester.getRect(find.byTooltip('Send'));
    final field = tester.getRect(find.byType(TextField));
    expect((send.bottom - field.bottom).abs(), lessThan(14));
  });

  testWidgets('the field runs the way what is typed in it reads', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(_composer(controller: controller, focus: focus)),
    );
    TextDirection? directionOfField() =>
        tester.widget<TextField>(find.byType(TextField)).textDirection;

    // Nothing typed: no opinion, so the placeholder stays where it is.
    expect(directionOfField(), isNull);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(directionOfField(), TextDirection.ltr);

    // The first Persian letter turns it right to left...
    await tester.enterText(find.byType(TextField), 'سلام');
    await tester.pump();
    expect(directionOfField(), TextDirection.rtl);

    // ...a leading number does not decide, the first letter after it does...
    await tester.enterText(find.byType(TextField), '123 سلام');
    await tester.pump();
    expect(directionOfField(), TextDirection.rtl);

    // ...and clearing it hands the field back.
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(directionOfField(), isNull);
  });

  testWidgets('reads in both themes', (tester) async {
    for (final mode in [ThemeMode.dark, ThemeMode.light]) {
      await tester.pumpWidget(
        _host(
          _composer(controller: controller, focus: focus, onAttach: () {}),
          mode: mode,
        ),
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('hello'), findsOneWidget);
    }
  });
}
