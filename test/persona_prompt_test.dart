// A guard for the crash the name prompt used to cause: its controller was
// disposed the instant a pop was requested, so the dialog's exit animation
// rebuilt a field whose controller was already gone — "used after being
// disposed", cascading into a framework assertion. The prompt now owns its
// controller and disposes it in State.dispose; this pumps the exit animation
// to completion, which is where the old crash fired.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/personas_dialog.dart';

void main() {
  testWidgets('the name prompt survives its own exit animation', (
    tester,
  ) async {
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await askPersonaName(
                  context,
                  title: 'New profile',
                  saveLabel: 'Create',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Work');
    await tester.tap(find.text('Create'));
    // The pop's exit transition runs here; the disposed-controller crash used
    // to be thrown mid-animation.
    await tester.pumpAndSettle();

    expect(result, 'Work', reason: 'the trimmed name comes back');
    expect(tester.takeException(), isNull, reason: 'and nothing was thrown');
  });

  testWidgets('cancelling returns null and also stays quiet', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await askPersonaName(context, title: 'Rename');
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(tester.takeException(), isNull);
  });
}
