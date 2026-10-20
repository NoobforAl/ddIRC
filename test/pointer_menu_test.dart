// A menu opens where it was asked for.
//
// The app draws its own title strip above the navigator, so the overlay a menu
// is placed in starts below the top of the window. The point a menu is asked
// to open at is a window position; placed in overlay coordinates unconverted,
// every menu opened the strip's height — 34 pixels — below the pointer.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/menu.dart';

const _strip = 34.0;

Widget _app(VoidCallback Function(BuildContext) open) => MaterialApp(
  theme: Tokens.themeFor(Tokens.dark),
  // The same shape as `WindowFrame`: a strip, then everything else.
  builder: (context, child) => Column(
    children: [
      const SizedBox(height: _strip),
      Expanded(child: child!),
    ],
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => Center(
        child: TextButton(onPressed: open(context), child: const Text('go')),
      ),
    ),
  ),
);

void main() {
  testWidgets('opens at the point asked for, not a title strip below it', (
    tester,
  ) async {
    const at = Offset(200, 300);

    await tester.pumpWidget(
      _app(
        (context) =>
            () => showPointerMenu<String>(
              context,
              at: at,
              items: const [
                PopupMenuItem(value: 'one', child: Text('First item')),
              ],
            ),
      ),
    );

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final item = tester.getRect(find.text('First item'));
    // The item sits a little inside the menu's padding, so it is a few pixels
    // under the point — but nowhere near 34 under it.
    expect(item.top, greaterThanOrEqualTo(at.dy));
    expect(item.top, lessThan(at.dy + _strip - 8));
    expect(item.left, greaterThanOrEqualTo(at.dx));
  });

  testWidgets(
    'a menu asked for on the right opens towards the room, leftwards',
    (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      const at = Offset(780, 200);
      await tester.pumpWidget(
        _app(
          (context) =>
              () => showPointerMenu<String>(
                context,
                at: at,
                items: const [
                  PopupMenuItem(value: 'one', child: Text('First item')),
                ],
              ),
        ),
      );

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();

      // Entirely on screen, not hanging off the right edge.
      expect(
        tester.getRect(find.text('First item')).right,
        lessThanOrEqualTo(800),
      );
    },
  );
}
