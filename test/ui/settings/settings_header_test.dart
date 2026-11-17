// Whether a settings page header says what it is for without being cut.
//
// The Notifications page used to read "Staying connected while you are
// elsewhere, and hearing about it" under its title. The header gives a subtitle
// one line and ellipsises the rest, and on a 360 dp phone that was cut at
// "hearin…" — a label, and cut, which reads as a bug in the one place meant to
// be a plain label.
//
// This measures the painted text. `flutter test` draws every glyph as a full
// square unless a real font is loaded, so a fit check with the stand-in font
// fails for any real sentence and proves nothing. Roboto is what an Android
// phone draws these in (the theme leaves the family unset), so a copy of it,
// kept in `test/fixtures/fonts/`, is loaded here under its own name, and the
// answer is the one a phone would give.
//
// It lives in a file of its own because a loaded font is global to the test
// isolate: loaded in `settings_shell_test.dart` it would change how wide every
// other test's text is, and several of those are about exactly that.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

/// Phones, in dp. 360 is the common one and what the cut was seen on; 320 is
/// the narrowest still in use, where a header has the least room.
const _widths = [360.0, 320.0];

/// What every page of the app settings says under its title, and which page
/// says it. Exact, so the old wording coming back is a failure of its own and
/// not only of the fit.
const _subtitles = {
  'Appearance': 'How it looks, and how much it says',
  'Notifications': 'Staying connected, and hearing about it',
  'Privacy': 'What is kept, and what is always on',
};

/// The wording that was cut, kept verbatim as the control.
const _oldWording =
    'Staying connected while you are elsewhere, and hearing about it';

/// Roboto Regular, from `test/fixtures/fonts/`.
///
/// A file in the repository and not one read out of the Flutter SDK. The SDK has
/// it only once a Flutter build has fetched it: a machine that has built the app
/// does, a clean CI runner does not, and the first version of this test found
/// the font on a developer's machine and failed on every runner. The path is
/// relative to the repository root, which is where `flutter test` runs, as the
/// icon test's reads of `assets/` already assume.
///
/// If it is missing the test fails and says so, rather than skipping: a skipped
/// fit check looks exactly like a passing one.
const _robotoPath = 'test/fixtures/fonts/Roboto-Regular.ttf';

Future<void> _loadRoboto() async {
  final file = File(_robotoPath);
  if (!file.existsSync()) {
    throw StateError(
      '$_robotoPath is missing. The header fit check cannot run without a '
      'real font, and must not pass without one.',
    );
  }
  final loader = FontLoader('Roboto')
    ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await loader.load();
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadRoboto);

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

  void sized(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// Whether the one line under a title was cut.
  bool cut(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.text(text)).didExceedMaxLines;

  /// The app settings, with the scopes nested as `main.dart` nests them,
  /// because opening a page builds sections that reach for most of them.
  Future<void> pumpSettings(WidgetTester tester) async {
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
  }

  for (final width in _widths) {
    group('at $width dp', () {
      for (final MapEntry(key: page, value: subtitle) in _subtitles.entries) {
        testWidgets('$page says "$subtitle" on one line', (tester) async {
          sized(tester, width);
          await pumpSettings(tester);

          await tester.tap(find.text(page));
          await tester.pumpAndSettle();

          expect(find.text(subtitle), findsOneWidget);
          expect(cut(tester, subtitle), isFalse, reason: 'cut at $width dp');
        });
      }

      // The control. A fit check that cannot fail is worse than none, so the
      // wording that was cut must still be reported as cut here: the same
      // header, the same font, with the old sentence in it.
      testWidgets('the old wording is still seen to be cut', (tester) async {
        sized(tester, width);
        await tester.pumpWidget(
          MaterialApp(
            theme: Tokens.themeFor(Tokens.dark),
            home: Scaffold(
              body: SettingsDialog(
                title: 'Notifications',
                subtitle: _oldWording,
                onBack: () {},
                children: const [],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(cut(tester, _oldWording), isTrue);
      });
    });
  }
}
