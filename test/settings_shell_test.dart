// Tests for the shape of a settings dialog, and for where its pages live.
//
// Two things are worth pinning here, and neither is visual polish.
//
// The first is that one shell has two shapes. Nine surfaces are built on
// `SettingsDialog`, and the reason it adapts rather than being replaced by a
// second route tree on phones is that two presentations would be two things to
// keep in step. A test that only ever pumped one width would let the other rot
// quietly, which is exactly the failure the shared shell was chosen to avoid.
//
// The second is that folding settings into pages never conceals an answer.
// That principle already covers the nav rows; splitting Connection in two puts
// it under real strain, because the switch that decides whether ddIRC survives
// being put away now sits on a page named after something else. The index row
// is what pays that back, and it has to say which way the switch is set even —
// especially — when the answer is no.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/app_lock.dart';
import 'package:ddirc/src/model/local_server.dart';
import 'package:ddirc/src/model/profile.dart';
import 'package:ddirc/src/model/proxy.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/model/tor.dart';
import 'package:ddirc/src/model/workspace.dart';
import 'package:ddirc/src/theme.dart';
import 'package:ddirc/src/ui/settings/app_settings_dialog.dart';
import 'package:ddirc/src/ui/settings/settings_chrome.dart';

/// The keychain, which a test host does not have.
const _keychain = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// A phone: narrower than [Layout.mediumAt], so the shell goes full bleed.
const _phone = Size(400, 800);

/// A desktop window, where a dialog can float over something.
const _desktop = Size(1400, 1000);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      _keychain,
      (call) async => call.method == 'read' ? null : true,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(_keychain, null);
  });

  void sized(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Push a settings dialog the way the app does — through `showDialog`, so it
  /// is a route above the app and reads the ambient MediaQuery rather than any
  /// LayoutScope, which is the situation it is actually built in.
  Future<void> open(
    WidgetTester tester, {
    VoidCallback? onBack,
    List<Widget> children = const [
      SettingsReadout(label: 'Inside', value: 'a setting'),
    ],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => SettingsDialog(
                title: 'App settings',
                onBack: onBack,
                children: children,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The panel itself, not the padded box the dialog route fills the screen
  /// with. This is the surface the user sees a border and a background on.
  Rect panel(WidgetTester tester) => tester.getRect(
    find
        .descendant(of: find.byType(Dialog), matching: find.byType(Material))
        .first,
  );

  group('one shell, two shapes', () {
    testWidgets('on a phone it takes the whole screen', (tester) async {
      sized(tester, _phone);
      await open(tester);

      // Not "roughly": there is no inset left to leave a strip of the app
      // showing, because on a screen this size that strip was costing a
      // seventh of the room while covering the rest anyway.
      expect(panel(tester).size, _phone);
    });

    testWidgets('on a desktop it stays a card over the app', (tester) async {
      sized(tester, _desktop);
      await open(tester);

      final rect = panel(tester);
      expect(rect.width, 420);
      // Inset on every side, so the conversation is visibly still there behind
      // it — which is what says this is a detour rather than a new screen.
      expect(rect.left, greaterThan(0));
      expect(rect.top, greaterThan(0));
      expect(rect.bottom, lessThan(_desktop.height));
    });

    testWidgets('a short page still owns a phone screen rather than '
        'floating as a band across the middle of it', (tester) async {
      sized(tester, _phone);
      await open(
        tester,
        children: const [SettingsReadout(label: 'One', value: 'row')],
      );

      // Shrink-wrapped, this would be a header and a single row hanging in
      // the vertical centre with the app showing above and below it.
      expect(panel(tester).height, _phone.height);
    });
  });

  group('the system back gesture', () {
    testWidgets('goes up one level on a phone, rather than closing', (
      tester,
    ) async {
      sized(tester, _phone);
      var backs = 0;
      await open(tester, onBack: () => backs++);

      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();

      // Full bleed leaves the gesture as the only way back, so it has to mean
      // what the arrow in the header means. Closing a four-page dialog from
      // its second page would be answering a different question.
      //
      // Asserted on the dialog rather than on what `maybePop` returned, which
      // is true either way: it reports that somebody answered, not that the
      // route went.
      expect(backs, 1);
      expect(find.byType(SettingsDialog), findsOneWidget);
    });

    testWidgets('closes on a desktop, where it is Escape and the barrier', (
      tester,
    ) async {
      sized(tester, _desktop);
      var backs = 0;
      await open(tester, onBack: () => backs++);

      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();

      // There, both of those mean "I am finished" and the back arrow is on
      // screen beside them for the other question.
      expect(backs, 0);
      expect(find.byType(SettingsDialog), findsNothing);
    });

    testWidgets('closes on a phone when there is no level to go up to', (
      tester,
    ) async {
      sized(tester, _phone);
      await open(tester);

      await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
      await tester.pumpAndSettle();

      expect(find.byType(SettingsDialog), findsNothing);
    });
  });

  group('SettingsActions', () {
    Future<void> row(WidgetTester tester, double width) => tester.pumpWidget(
      MaterialApp(
        theme: Tokens.themeFor(Tokens.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: SettingsActions(
                children: [
                  SettingsDangerButton(
                    label: 'Delete & disconnect',
                    onPressed: () {},
                  ),
                  SettingsTertiaryButton(label: 'Save', onPressed: () {}),
                  SettingsPrimaryButton(
                    label: 'Save & connect',
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    testWidgets('wraps rather than painting stripes over the primary action', (
      tester,
    ) async {
      await row(tester, 300);

      // A Row answers "these do not fit" by overflowing, and what it overflows
      // is the end of the line — which is where the button the user came to
      // press is deliberately kept.
      expect(tester.takeException(), isNull);
      final first = tester.getRect(find.text('Delete & disconnect'));
      final last = tester.getRect(find.text('Save & connect'));
      expect(last.top, greaterThan(first.bottom - first.height));
    });

    testWidgets('is still one line where there is room for one', (
      tester,
    ) async {
      await row(tester, 800);

      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.text('Delete & disconnect')).center.dy,
        tester.getRect(find.text('Save & connect')).center.dy,
      );
    });
  });

  group('the app settings index', () {
    /// The scopes nested exactly as `main.dart` nests them, because opening a
    /// page builds sections that reach for most of them.
    Future<AppSettings> pump(WidgetTester tester) async {
      final settings = await AppSettings.load();
      final profiles = await ProfileStore.load();
      final tor = await TorSettings.load();
      final proxies = await ProxySettings.load(tor: tor);
      final workspace = Workspace(
        profiles: profiles,
        settings: settings,
        proxies: proxies,
      );
      addTearDown(workspace.dispose);

      await tester.pumpWidget(
        AppLockScope(
          settings: await AppLockSettings.load(),
          child: SettingsScope(
            settings: settings,
            child: ProfileScope(
              store: profiles,
              child: ProxyScope(
                settings: proxies,
                child: TorScope(
                  tor: tor,
                  child: LocalServerScope(
                    server: await LocalServerSettings.load(profiles: profiles),
                    child: WorkspaceScope(
                      workspace: workspace,
                      child: MaterialApp(
                        theme: Tokens.themeFor(Tokens.dark),
                        home: const Scaffold(body: AppSettingsDialog()),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return settings;
    }

    testWidgets('leads to four pages, not three', (tester) async {
      sized(tester, _desktop);
      await pump(tester);

      expect(find.byType(SettingsNavRow), findsNWidgets(4));
      for (final page in [
        'Appearance',
        'Connection',
        'Notifications',
        'Privacy',
      ]) {
        expect(find.text(page), findsOneWidget, reason: page);
      }
    });

    testWidgets('says whether ddIRC stays connected without being opened', (
      tester,
    ) async {
      sized(tester, _desktop);
      final settings = await pump(tester);

      // Stated when the answer is no, which is the whole point: this switch
      // now lives on a page named after notifications, and a summary that
      // mentioned it only when it was on would say nothing by its silence to
      // the person checking whether they are still reachable.
      expect(find.textContaining('Not staying connected'), findsOneWidget);

      settings.runInBackground = true;
      await tester.pumpAndSettle();
      expect(find.textContaining('Staying connected'), findsOneWidget);
      expect(find.textContaining('Not staying connected'), findsNothing);
    });

    testWidgets('and the switch itself is one press away, on that page', (
      tester,
    ) async {
      sized(tester, _desktop);
      await pump(tester);

      await tester.tap(find.text('Notifications'));
      await tester.pumpAndSettle();

      // Moved off Connection, where its own page's summary line had never
      // once mentioned it, and onto the page about being away.
      expect(find.text('Stay connected in the background'), findsOneWidget);
      expect(find.text('Notify me about messages'), findsOneWidget);
    });

    testWidgets('and Connection goes on describing only the route', (
      tester,
    ) async {
      sized(tester, _desktop);
      final settings = await pump(tester);

      final before = tester
          .widgetList<SettingsNavRow>(find.byType(SettingsNavRow))
          .firstWhere((row) => row.label == 'Connection')
          .summary;

      settings.runInBackground = true;
      settings.notifications = false;
      await tester.pumpAndSettle();

      // The evidence the split was made on, kept as a test rather than left in
      // a commit message: this row has never once mentioned staying connected
      // or notifications, because they were never what the page was about.
      // They sat on it for being connection-adjacent.
      //
      // Asserted through the row rather than by opening the page, which cannot
      // be built here at all — GlobalProxySection asks the core for the Tor
      // port, and there is no core in a widget test.
      expect(
        tester
            .widgetList<SettingsNavRow>(find.byType(SettingsNavRow))
            .firstWhere((row) => row.label == 'Connection')
            .summary,
        before,
      );
      expect(before, isNot(contains('connected')));
    });
  });
}
