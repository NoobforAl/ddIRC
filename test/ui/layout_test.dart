// Tests for the layout tokens.
//
// The breakpoints themselves are design decisions and are meant to be tunable,
// so nothing here asserts a particular width. What is asserted is the shape of
// the answers: that the two decisions happen in the right order, that a
// drawer never swallows the whole screen, and that a widget with no
// LayoutScope above it still gets a sensible answer rather than throwing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/ui/layout.dart';

void main() {
  group('Layout.forWidth', () {
    test('widens through all three sizes', () {
      expect(Layout.forWidth(360), Layout.compact);
      expect(Layout.forWidth(Layout.mediumAt), Layout.medium);
      expect(Layout.forWidth(Layout.expandedAt), Layout.expanded);
      expect(Layout.forWidth(2560), Layout.expanded);
    });

    test('is inclusive at each breakpoint', () {
      expect(Layout.forWidth(Layout.mediumAt - 0.01), Layout.compact);
      expect(Layout.forWidth(Layout.expandedAt - 0.01), Layout.medium);
    });

    test('pins the channel list before the member list', () {
      // The order matters: a screen that showed members but hid channels
      // would be showing the panel you need least and hiding the one you
      // navigate with.
      expect(Layout.compact.channelsPinned, isFalse);
      expect(Layout.compact.membersPinned, isFalse);
      expect(Layout.medium.channelsPinned, isTrue);
      expect(Layout.medium.membersPinned, isFalse);
      expect(Layout.expanded.channelsPinned, isTrue);
      expect(Layout.expanded.membersPinned, isTrue);
    });

    test('gives a phone a narrower gutter', () {
      expect(Layout.compact.gutter, lessThan(Layout.medium.gutter));
      expect(Layout.medium.gutter, Layout.expanded.gutter);
    });
  });

  group('Layout.drawerWidth', () {
    test('takes the width it wants when there is room', () {
      expect(Layout.drawerWidth(800, preferred: 300), 300);
    });

    test('always leaves some of the conversation showing', () {
      // The strip left over is what says the drawer is covering something
      // rather than being a screen of its own.
      final width = Layout.drawerWidth(320, preferred: 300);
      expect(width, lessThan(320));
    });
  });

  group('Layout.of', () {
    testWidgets('reads the scope when there is one', (tester) async {
      late Layout seen;
      await tester.pumpWidget(
        MediaQuery(
          // Deliberately disagreeing with the scope: the scope measures the
          // room the app has, which on desktop is not the whole window.
          data: const MediaQueryData(size: Size(1600, 900)),
          child: LayoutScope(
            layout: Layout.compact,
            child: Builder(
              builder: (context) {
                seen = context.layout;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(seen, Layout.compact);
    });

    testWidgets('falls back to the window for dialogs and other routes', (
      tester,
    ) async {
      late Layout seen;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: Builder(
            builder: (context) {
              seen = context.layout;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, Layout.compact);
    });
  });
}
