// Tests for how dialogs and pages arrive.
//
// What the user was seeing was not a slow animation but a broken one: the form
// froze for a third of a second while it was built, then skipped most of its
// transition and was in place — with the screen behind it showing through for
// the frames in between. So these pin the properties that make a transition
// followable rather than its timings: it starts after the page exists, a full
// page never fades through what it covers, and announcing itself as a page
// never costs a second build.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/motion.dart';

const _pageKey = Key('page');
const _tall = Size(400, 800);

Widget _app({required WidgetBuilder builder, bool reduceMotion = false}) {
  return MaterialApp(
    theme: Tokens.themeFor(Tokens.dark),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () =>
                showSoftDialog<void>(context: context, builder: builder),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(
  WidgetTester tester,
  WidgetBuilder builder, {
  bool reduceMotion = false,
}) async {
  await tester.binding.setSurfaceSize(_tall);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_app(builder: builder, reduceMotion: reduceMotion));
  await tester.tap(find.text('open'));
}

/// A page-shaped child: fills the space it is given and says it is a page.
Widget _page(BuildContext context) {
  claimFullBleed(context);
  return const SizedBox.expand(
    key: _pageKey,
    child: ColoredBox(color: Colors.red),
  );
}

/// Every opacity above [key] in the transition, so none can be hiding.
List<double> _opacitiesAbove(WidgetTester tester, Key key) => tester
    .widgetList<FadeTransition>(
      find.ancestor(of: find.byKey(key), matching: find.byType(FadeTransition)),
    )
    .map((f) => f.opacity.value)
    .toList();

void main() {
  group('a dialog is brought in after it has been built', () {
    testWidgets('a long first frame does not use up the animation', (
      tester,
    ) async {
      late Animation<double> animation;
      await _open(tester, (context) {
        animation = ModalRoute.of(context)!.animation!;
        return const SizedBox.expand();
      });

      // The frame that builds the page takes 200 ms. With the clock started in
      // that frame, the next one would find the animation more than half over.
      await tester.pump(const Duration(milliseconds: 200));
      expect(animation.value, lessThan(0.05));

      // Then it plays, over its own length, from the start.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 100));
      expect(animation.value, inExclusiveRange(0.1, 0.6));

      await tester.pumpAndSettle();
      expect(animation.value, 1);
    });

    testWidgets('dismissing it before it has started leaves nothing behind', (
      tester,
    ) async {
      await _open(tester, (context) => const SizedBox.expand(key: _pageKey));
      // Popped in the same frame it was pushed in.
      Navigator.of(tester.element(find.text('open'))).pop();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(_pageKey), findsNothing, reason: 'it is gone');
      expect(find.text('open'), findsOneWidget, reason: 'and the app is back');
    });

    testWidgets('with reduced motion it is simply there', (tester) async {
      await _open(tester, _page, reduceMotion: true);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getTopLeft(find.byKey(_pageKey)), Offset.zero);
    });
  });

  group('a dialog can be dismissed the way every dialog can', () {
    // Found by a test written for something else. Holding the animation back
    // until the page was built left the dimmed area behind a dialog ignoring
    // taps for good — it only learns it may stop when the route says its state
    // changed — so no dialog in the app could be tapped away.
    Widget floating(BuildContext context) =>
        const Center(child: SizedBox(key: _pageKey, width: 100, height: 100));

    testWidgets('tapping the dimmed area closes it', (tester) async {
      await _open(tester, floating);
      await tester.pumpAndSettle();
      expect(find.byKey(_pageKey), findsOneWidget);

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byKey(_pageKey), findsNothing);
    });

    testWidgets('and it can be tapped away at once, not only once settled', (
      tester,
    ) async {
      await _open(tester, floating);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byKey(_pageKey), findsNothing);
    });

    testWidgets('the back gesture closes it', (tester) async {
      await _open(tester, _page);
      await tester.pumpAndSettle();
      expect(find.byKey(_pageKey), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byKey(_pageKey), findsNothing);
    });

    testWidgets('one that must be answered ignores the dimmed area', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(_tall);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: Tokens.themeFor(Tokens.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showSoftDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: floating,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();

      expect(find.byKey(_pageKey), findsOneWidget);
    });
  });

  group('a page that fills the screen', () {
    testWidgets('is opaque the whole way, so nothing shows through it', (
      tester,
    ) async {
      await _open(tester, _page);
      await tester.pump(); // build
      await tester.pump(const Duration(milliseconds: 16)); // the clock starts
      await tester.pump(const Duration(milliseconds: 16)); // the flag lands
      await tester.pump(const Duration(milliseconds: 100)); // mid-flight

      expect(_opacitiesAbove(tester, _pageKey), everyElement(1.0));
    });

    testWidgets('travels up from the bottom edge and comes to rest', (
      tester,
    ) async {
      await _open(tester, _page);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 60));
      final early = tester.getTopLeft(find.byKey(_pageKey)).dy;

      await tester.pump(const Duration(milliseconds: 100));
      final later = tester.getTopLeft(find.byKey(_pageKey)).dy;

      expect(early, inExclusiveRange(0, _tall.height));
      expect(later, lessThan(early), reason: 'it is moving, and upwards');

      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.byKey(_pageKey)).dy, 0);
    });

    testWidgets('is built once, not again when it says it is a page', (
      tester,
    ) async {
      var built = 0;
      await _open(tester, (context) {
        claimFullBleed(context);
        return _Counts(onInit: () => built++);
      });
      await tester.pumpAndSettle();
      expect(built, 1, reason: 'the wrappers must not change under it');
    });
  });

  group('a dialog that floats', () {
    testWidgets('fades in rather than arriving opaque', (tester) async {
      await _open(tester, (context) {
        return const Center(
          child: SizedBox(key: _pageKey, width: 100, height: 100),
        );
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(milliseconds: 40));

      expect(_opacitiesAbove(tester, _pageKey).any((o) => o < 1), isTrue);
      await tester.pumpAndSettle();
      expect(_opacitiesAbove(tester, _pageKey), everyElement(1.0));
    });
  });

  group('the curves and distances', () {
    for (final (name, curve) in [
      ('curve', Motion.curve),
      ('exit', Motion.exit),
      ('glide', Motion.glide),
    ]) {
      test('$name never overshoots and never goes backwards', () {
        var last = 0.0;
        for (var i = 0; i <= 100; i++) {
          final v = curve.transform(i / 100);
          expect(v, inInclusiveRange(0, 1), reason: '$name at $i%');
          expect(v, greaterThanOrEqualTo(last - 1e-9), reason: '$name at $i%');
          last = v;
        }
        expect(curve.transform(1), closeTo(1, 1e-9));
      });
    }

    testWidgets('a long scroll takes longer than a short one, within limits', (
      tester,
    ) async {
      late Motion motion;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              motion = context.motion;
              return const SizedBox();
            },
          ),
        ),
      );
      final short = motion.travel(200);
      final long = motion.travel(4000);
      final absurd = motion.travel(1e7);

      expect(short, motion.travel(0), reason: 'a floor, so it never blinks');
      expect(long, greaterThan(short));
      expect(absurd, const Duration(milliseconds: 720));
      expect(short, greaterThanOrEqualTo(const Duration(milliseconds: 320)));
    });

    testWidgets('and takes no time at all under reduced motion', (
      tester,
    ) async {
      late Motion motion;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              motion = context.motion;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(motion.travel(4000), Duration.zero);
    });
  });
}

/// Counts how many times it has been brought into the tree.
class _Counts extends StatefulWidget {
  const _Counts({required this.onInit});

  final VoidCallback onInit;

  @override
  State<_Counts> createState() => _CountsState();
}

class _CountsState extends State<_Counts> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}
