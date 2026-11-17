// A disabled menu row has to say why. The reason used to be glued onto the
// label, where a narrow menu cut off exactly the part that explained it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/menu.dart';

Widget _host(Widget child) => MaterialApp(
  theme: Tokens.themeFor(Tokens.dark),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('a disabled row shows its reason under the label', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const MenuRow(
          icon: Icons.search_rounded,
          label: 'Search in conversation',
          note: 'Open a channel first',
          enabled: false,
        ),
      ),
    );
    expect(find.text('Search in conversation'), findsOneWidget);
    expect(find.text('Open a channel first'), findsOneWidget);
  });

  testWidgets('an enabled row has nothing to explain', (tester) async {
    await tester.pumpWidget(
      _host(
        const MenuRow(
          icon: Icons.search_rounded,
          label: 'Search in conversation',
          note: 'Open a channel first',
        ),
      ),
    );
    expect(find.text('Search in conversation'), findsOneWidget);
    expect(find.text('Open a channel first'), findsNothing);
  });
}
