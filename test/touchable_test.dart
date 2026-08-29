// Tests for the pointer-feedback surface.
//
// The theme removes Material's splash and press highlight, so nothing else in
// the tree is going to notice a click for us. These check that the state a row
// paints from actually tracks the pointer — including letting go, which is the
// part that leaves a surface stuck lit if it is wrong.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/ui/touchable.dart';

void main() {
  /// The most recent state the builder was handed.
  late Touch latest;

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onTap,
    ValueChanged<Offset>? onContextMenu,
  }) {
    latest = Touch.none;
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Touchable(
              onTap: onTap,
              onContextMenu: onContextMenu,
              builder: (context, touch) {
                latest = touch;
                return const SizedBox(width: 80, height: 40);
              },
            ),
          ),
        ),
      ),
    );
  }

  /// A mouse parked over the surface, removed again when the test ends.
  Future<TestGesture> hover(WidgetTester tester) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(Touchable)));
    await tester.pumpAndSettle();
    return gesture;
  }

  testWidgets('reports hover while the pointer is over it', (tester) async {
    await pump(tester, onTap: () {});
    expect(latest, Touch.none);

    final gesture = await hover(tester);
    expect(latest, Touch.hover);

    await gesture.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(latest, Touch.none);
  });

  testWidgets('reports press between tap down and tap up', (tester) async {
    var taps = 0;
    await pump(tester, onTap: () => taps++);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Touchable)),
    );
    await tester.pump();
    expect(latest, Touch.press);

    await gesture.up();
    await tester.pumpAndSettle();
    expect(latest, Touch.none);
    expect(taps, 1);
  });

  testWidgets('lets go when the press is cancelled', (tester) async {
    await pump(tester, onTap: () {});

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(Touchable)),
    );
    await tester.pump();
    expect(latest, Touch.press);

    // Sliding off mid-press. The surface must not stay lit under a pointer
    // that has gone somewhere else.
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(latest, Touch.none);
  });

  testWidgets('a surface with no action never lights up', (tester) async {
    await pump(tester);
    await hover(tester);
    expect(latest, Touch.none);
  });

  group('the context gesture', () {
    // Right-click and long-press are one question with two input devices, and
    // the surface has to answer both the same way — including with a point,
    // since a menu has to open somewhere.

    testWidgets('a right-click reports where the pointer was', (tester) async {
      Offset? at;
      await pump(tester, onTap: () {}, onContextMenu: (o) => at = o);

      final centre = tester.getCenter(find.byType(Touchable));
      // Off-centre on purpose: a menu opens under the pointer, not under the
      // middle of whatever the pointer happened to be over.
      final point = centre + const Offset(20, 10);
      await tester.tapAt(point, buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(at, point);
    });

    testWidgets('a long press reports the middle of the row', (tester) async {
      Offset? at;
      await pump(tester, onTap: () {}, onContextMenu: (o) => at = o);

      final centre = tester.getCenter(find.byType(Touchable));
      await tester.longPressAt(centre + const Offset(20, 10));
      await tester.pumpAndSettle();

      // Not where the finger was: a finger covers what it presses, so the
      // menu is anchored to the row instead.
      expect(at, centre);
    });

    testWidgets('a right-click is never mistaken for a tap', (tester) async {
      var taps = 0;
      await pump(tester, onTap: () => taps++);

      await tester.tap(find.byType(Touchable), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      // A surface with nothing to offer does nothing, rather than falling
      // through to whatever the left button would have done.
      expect(taps, 0);
    });
  });

  test('press is a stronger wash than hover, and idle is none', () {
    expect(Touch.none.wash, 0);
    expect(Touch.hover.wash, greaterThan(Touch.none.wash));
    expect(Touch.press.wash, greaterThan(Touch.hover.wash));
    // Never all the way: a hovered row would then be indistinguishable from
    // the selected one, which is the whole point of keeping them apart.
    expect(Touch.press.wash, lessThan(1));
  });
}
