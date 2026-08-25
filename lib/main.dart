// ddIRC - a minimal, modern IRC client.
//
// The Rust core (ddirc-core) owns the connection, protocol and state. This
// layer only routes and presents: it never parses IRC, and everything it
// renders has already been sanitised on the Rust side.

import 'dart:async';

import 'package:flutter/material.dart';

import 'src/model/log.dart';
import 'src/model/profile.dart';
import 'src/model/proxy.dart';
import 'src/model/settings.dart';
import 'src/model/workspace.dart';
import 'src/rust/frb_generated.dart';
import 'src/theme.dart';
import 'src/ui/background.dart';
import 'src/ui/boot_screen.dart';
import 'src/ui/window_chrome.dart';
import 'src/ui/workspace_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Preferences and saved networks are read before the first frame, so
  // nothing renders with defaults and then visibly reflows. Both are a
  // key/value read on the platform's own store — no network, no native
  // library, nothing that can hang. Settings come first because the window
  // itself is painted in the chosen theme.
  final settings = await AppSettings.load();
  // Resolve the log directory whether or not logging is on, so the settings
  // screen can show the path before the user commits to enabling anything.
  // Nothing is created on disk until there is a line to write.
  await AppLog.instance.start();
  _followLogSettings(settings);
  // Reconfigure the window while it is still hidden, so the native caption
  // never flashes before ours replaces it.
  await prepareWindow(Tokens.forMode(settings.themeMode));
  final profiles = await ProfileStore.load();
  final proxies = await ProxySettings.load();
  runApp(DdIrcApp(settings: settings, profiles: profiles, proxies: proxies));
}

/// Keep the log in step with the two switches that control it.
///
/// A listener rather than a read at startup, so turning logging off stops it
/// immediately — a user who has just realised they are recording a
/// conversation should not have to relaunch to make it stop.
void _followLogSettings(AppSettings settings) {
  void apply() => AppLog.instance.configure(
    chat: settings.saveChatLogs,
    debug: settings.saveDebugLogs,
  );

  apply();
  settings.addListener(apply);
}

/// Bring up the native core.
///
/// The only part of startup that is slow, and the only part that can fail: it
/// is a dynamic library resolved by the operating system, so it can be
/// missing, be the wrong architecture, or be a build that does not match these
/// bindings. Everything else is already in memory by the time this runs, which
/// is why it is the only thing behind the splash.
///
/// Guarded rather than blindly called, because [BootScreen] retries: the
/// bridge throws on a second initialisation, and a failure late in the first
/// one can still have left it marked as initialised.
Future<void> startCore() async {
  if (RustLib.instance.initialized) return;
  await RustLib.init();
}

class DdIrcApp extends StatefulWidget {
  const DdIrcApp({
    super.key,
    required this.settings,
    required this.profiles,
    required this.proxies,
  });

  final AppSettings settings;
  final ProfileStore profiles;
  final ProxySettings proxies;

  @override
  State<DdIrcApp> createState() => _DdIrcAppState();
}

class _DdIrcAppState extends State<DdIrcApp> {
  late final Workspace _workspace = Workspace(
    profiles: widget.profiles,
    settings: widget.settings,
    proxies: widget.proxies,
  );

  /// Owns what happens when the window is closed. Inert off desktop.
  late final BackgroundPresence _background = BackgroundPresence(
    settings: widget.settings,
    workspace: _workspace,
  );

  @override
  void initState() {
    super.initState();
    // Not awaited, and nothing waits on it: this arranges what a later close
    // will do, and the window cannot be closed before the first frame.
    unawaited(_background.start());
  }

  /// Bring up the core, then start the connections that were asked for.
  ///
  /// The auto-connects are deliberately not awaited: the splash is waiting on
  /// this, and a network that is down would otherwise hold the whole app
  /// behind it. They resolve into the workspace as they arrive.
  ///
  /// Here rather than in `main`, because until the core has loaded there is
  /// nothing to connect *with*.
  Future<void> _start() async {
    await startCore();
    unawaited(_workspace.connectAutomatic());
  }

  @override
  void dispose() {
    _background.dispose();
    // Closes every live connection, so quitting never leaves a socket behind.
    // Already done by the time a tray quit reaches here, and idempotent for
    // exactly that reason.
    _workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      settings: widget.settings,
      child: ProfileScope(
        store: widget.profiles,
        child: ProxyScope(
          settings: widget.proxies,
          child: WorkspaceScope(
            workspace: _workspace,
            // The theme is a setting, so the app itself has to listen: nothing
            // below rebuilds MaterialApp, and `themeMode` is read here.
            child: ListenableBuilder(
              listenable: widget.settings,
              builder: (context, _) => MaterialApp(
                title: 'ddIRC',
                debugShowCheckedModeBanner: false,
                theme: Tokens.themeFor(Tokens.light),
                darkTheme: Tokens.themeFor(Tokens.dark),
                themeMode: widget.settings.themeMode,
                // Wrapping here rather than per screen means every route — and
                // every dialog on the root navigator — sits under one frame.
                builder: (context, child) =>
                    WindowFrame(child: child ?? const SizedBox.shrink()),
                // Inside MaterialApp rather than around it, so the splash is
                // themed and cross-fades into the app. The scopes stay above
                // it, because dialogs are routes and must reach them.
                home: BootScreen(
                  load: _start,
                  builder: (context) => const WorkspaceScreen(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
