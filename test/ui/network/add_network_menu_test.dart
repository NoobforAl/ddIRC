// Where the Add menu opens on the empty screen.
//
// The menu is meant to come out from under the button that opened it, lined up
// with the button's left edge. On the empty screen it did not: the column the
// button sits in stretches its children, so the button's box was the width of
// the column while its label sat in the middle, and the menu opened from the
// column's left edge — well to the left of the button, and over the "App
// settings" row below it. The code said "lined up with its left edge" and was
// measuring the wrong box, so what is held here is the result the user sees,
// not the widget that produces it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/design/menu.dart';
import 'package:ddirc/src/ui/shell/workspace_screen.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  /// The Add button on the empty screen. `TextButton.icon` builds a private
  /// subclass, so it is found by what it is rather than by its exact type.
  Finder addButton() => find.ancestor(
    of: find.text('Add a network'),
    matching: find.byWidgetPredicate((w) => w is TextButton),
  );

  /// The empty screen on a phone: no networks, and narrow enough that the rail
  /// is folded away, which is the state every fresh install starts in and the
  /// only one where "App settings" is a button under the Add menu.
  Future<void> pumpEmpty(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final store = await ProfileStore.load();
    final workspace = Workspace(
      profiles: store,
      settings: await AppSettings.load(),
      proxies: await ProxySettings.load(),
    );
    addTearDown(workspace.dispose);

    await tester.pumpWidget(
      SettingsScope(
        settings: workspace.settings,
        child: ProfileScope(
          store: store,
          child: WorkspaceScope(
            workspace: workspace,
            child: MaterialApp(
              theme: Tokens.themeFor(Tokens.dark),
              home: const WorkspaceScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the menu opens under the Add button, not left of it', (
    tester,
  ) async {
    await pumpEmpty(tester);

    final button = addButton();

    // What the eye takes for the button's left edge is its icon, not the
    // `TextButton`'s own box: that box is the stretched, full-width one, which
    // is exactly the thing the menu used to be lined up with. Measuring it
    // here would repeat the mistake the test is about.
    final icon = tester.getRect(
      find.descendant(of: button, matching: find.byIcon(Icons.add)),
    );

    await tester.tap(button);
    await tester.pumpAndSettle();

    // The first row of the menu, not its panel: the panel's edge is an
    // implementation detail of the popup route, the row is what is read.
    final row = tester.getRect(find.byType(MenuRow).first);

    // Under the button, so below the icon…
    expect(row.top, greaterThanOrEqualTo(icon.bottom));
    // …and starting at the button's left, give or take the padding the button
    // and the menu each keep inside their own edge. Lined up with the
    // full-width box it began about a hundred points to the left of this; the
    // band is wide enough for the padding and far too narrow for that.
    expect(
      row.left - icon.left,
      inInclusiveRange(-24, 24),
      reason: 'menu row at ${row.left}, button icon at ${icon.left}',
    );
  });

  testWidgets('the button is its own size now, and still in the middle', (
    tester,
  ) async {
    await pumpEmpty(tester);

    final rect = tester.getRect(addButton());

    // The reason the menu lines up: the button's box fits the button. It used
    // to be as wide as the 340-point column with the label floating in it.
    expect(rect.width, lessThan(250));
    // And fitting it must not have moved it: it was centred by its own label
    // inside a full-width box, and is now centred as a whole.
    expect(rect.center.dx, closeTo(240, 1));
  });
}
