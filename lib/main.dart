// ddIRC - a minimal, modern IRC client.
//
// The Rust core (ddirc-core) owns the connection, protocol and state. This
// layer only routes and presents: it never parses IRC, and everything it
// renders has already been sanitised on the Rust side.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/model/local_server.dart';
import 'src/model/log.dart';
import 'src/model/profile.dart';
import 'src/model/proxy.dart';
import 'src/model/settings.dart';
import 'src/model/tor.dart';
import 'src/model/workspace.dart';
import 'src/rust/frb_generated.dart';
import 'src/theme.dart';
import 'src/ui/background.dart';
import 'src/ui/boot_screen.dart';
import 'src/ui/notification_router.dart';
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
  // Tor before the proxy settings, because the built-in route reads its port
  // from it. Neither starts anything here — this is a preference being read.
  final tor = await TorSettings.load();
  final proxies = await ProxySettings.load(tor: tor);
  // The local server owns one profile, so it needs the store. Like the two
  // above, this reads a preference and starts nothing.
  final localServer = await LocalServerSettings.load(profiles: profiles);
  runApp(
    DdIrcApp(
      settings: settings,
      profiles: profiles,
      proxies: proxies,
      tor: tor,
      localServer: localServer,
    ),
  );
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
    required this.tor,
    required this.localServer,
  });

  final AppSettings settings;
  final ProfileStore profiles;
  final ProxySettings proxies;
  final TorSettings tor;
  final LocalServerSettings localServer;

  @override
  State<DdIrcApp> createState() => _DdIrcAppState();
}

class _DdIrcAppState extends State<DdIrcApp> {
  late final Workspace _workspace = Workspace(
    profiles: widget.profiles,
    settings: widget.settings,
    proxies: widget.proxies,
    onLine: _notifications.router.onLine,
    onRead: _notifications.router.onRead,
  );

  /// Being told about a message while ddIRC is not the thing in front.
  ///
  /// Declared before [_workspace] is built because the workspace hands it every
  /// line; `late final` is what lets the two refer to each other without either
  /// having to be constructed first.
  late final Notifications _notifications = Notifications.create(
    settings: widget.settings,
    profiles: widget.profiles,
    onOpen: _openConversation,
  );

  /// Where a tapped notification lands.
  ///
  /// Selects the network before the conversation, because selecting a
  /// conversation on a session that is not the one on screen would move
  /// something the user cannot see. A network that has since disconnected is a
  /// tap on a notification for a conversation that no longer exists, and the
  /// honest response is to do nothing rather than to guess at a near miss.
  void _openConversation(String profileId, String conversation) {
    final session = _workspace.sessionFor(profileId);
    if (session == null) return;
    _workspace.select(profileId);
    session.select(conversation);
  }

  /// Built once, not per build.
  ///
  /// `ColorScheme.fromSeed` derives a full Material 3 tonal palette in a
  /// perceptual colour space, and both of these were being recomputed on every
  /// notification from [AppSettings] — which includes every progress tick
  /// while Tor bootstraps. Worse than the arithmetic: a fresh [ThemeData] is a
  /// different object, so the [Theme] above the app changed identity and every
  /// widget in the tree that reads `context.tokens` was rebuilt with it.
  ///
  /// The palette is a constant, so the theme is one too.
  static final ThemeData _light = Tokens.themeFor(Tokens.light);
  static final ThemeData _dark = Tokens.themeFor(Tokens.dark);

  /// The one setting [MaterialApp] actually reads.
  ///
  /// Listening to all of [AppSettings] meant rebuilding the app — and with it
  /// the navigator above every route — when the timestamps switch moved. This
  /// passes on a change only when the theme has genuinely changed.
  late final _themeMode = _Selected<ThemeMode>(
    widget.settings,
    () => widget.settings.themeMode,
  );

  /// Owns staying connected while the app is not the thing in front — a tray
  /// icon and a hidden window on desktop, a foreground service on Android,
  /// and nothing at all on iOS, which will not hold a socket open anyway.
  late final BackgroundKeeper _background = backgroundKeeperFor(
    settings: widget.settings,
    workspace: _workspace,
  );

  @override
  void initState() {
    super.initState();
    // Not awaited, and nothing waits on it: this arranges what a later close
    // will do, and nothing can be closed before the first frame.
    unawaited(_background.start());
    // Same again. Registering with the platform's notification service is not
    // something the first frame should wait behind, and a message cannot
    // arrive before there is a connection to carry it.
    unawaited(_notifications.start());
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
    // Awaited, and before the auto-connects: this returns as soon as Tor has
    // a port, not when Tor is ready, so the wait is short. What it buys is
    // that a network dialled a moment later finds the proxy already there.
    // Without it the first auto-connect would resolve its proxy against a Tor
    // that had not bound yet, and be refused for a reason that had already
    // stopped being true.
    await widget.tor.startIfEnabled();
    // Also awaited, and for a sharper reason than Tor's: the server asks the
    // operating system for a free port, so its profile does not know where to
    // dial until it has bound. An auto-connect that ran first would use last
    // session's port and fail against whatever holds it now.
    await widget.localServer.startIfEnabled();
    unawaited(_workspace.connectAutomatic());
  }

  @override
  void dispose() {
    _themeMode.dispose();
    _background.dispose();
    _notifications.dispose();
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
          child: TorScope(
            tor: widget.tor,
            child: LocalServerScope(
              server: widget.localServer,
              child: WorkspaceScope(
                workspace: _workspace,
                // The theme is a setting, so the app itself has to listen:
                // nothing below rebuilds MaterialApp, and `themeMode` is read
                // here. Only that one setting, though — see [_themeMode].
                child: ValueListenableBuilder<ThemeMode>(
                  valueListenable: _themeMode,
                  builder: (context, mode, _) => MaterialApp(
                    title: 'ddIRC',
                    debugShowCheckedModeBanner: false,
                    theme: _light,
                    darkTheme: _dark,
                    themeMode: mode,
                    // Wrapping here rather than per screen means every route —
                    // and every dialog on the root navigator — sits under one
                    // frame.
                    builder: (context, child) =>
                        WindowFrame(child: child ?? const SizedBox.shrink()),
                    // Inside MaterialApp rather than around it, so the splash
                    // is themed and cross-fades into the app. The scopes stay
                    // above it, because dialogs are routes and must reach them.
                    home: BootScreen(
                      load: _start,
                      builder: (context) => const WorkspaceScreen(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One derived value of a [Listenable], which notifies only when it changes.
///
/// The models here are whole-object notifiers: [AppSettings] tells its
/// listeners that *something* moved, not what. That is the right shape for a
/// settings dialog, which is showing all of it anyway, and the wrong shape for
/// a listener that cares about one field — it rebuilds for every change but
/// its own.
///
/// Reading through a function rather than taking a value keeps the source of
/// truth on the model. Nothing is mirrored, so nothing can go stale.
class _Selected<T> extends ChangeNotifier implements ValueListenable<T> {
  _Selected(this._source, this._read) : _value = _read() {
    _source.addListener(_check);
  }

  final Listenable _source;
  final T Function() _read;
  T _value;

  @override
  T get value => _value;

  void _check() {
    final next = _read();
    if (next == _value) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _source.removeListener(_check);
    super.dispose();
  }
}
