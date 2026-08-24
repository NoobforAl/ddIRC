// ddIRC - a minimal, modern IRC client.
//
// The Rust core (ddirc-core) owns the connection, protocol and state. This
// layer only routes and presents: it never parses IRC, and everything it
// renders has already been sanitised on the Rust side.

import 'package:flutter/material.dart';

import 'src/model/profile.dart';
import 'src/model/settings.dart';
import 'src/model/workspace.dart';
import 'src/rust/frb_generated.dart';
import 'src/theme.dart';
import 'src/ui/window_chrome.dart';
import 'src/ui/workspace_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Preferences and saved networks are read before the first frame, so
  // nothing renders with defaults and then visibly reflows. Settings come
  // first because the window itself is painted in the chosen theme.
  final settings = await AppSettings.load();
  // Reconfigure the window while it is still hidden, so the native caption
  // never flashes before ours replaces it.
  await prepareWindow(Tokens.forMode(settings.themeMode));
  await RustLib.init();
  final profiles = await ProfileStore.load();
  runApp(DdIrcApp(settings: settings, profiles: profiles));
}

class DdIrcApp extends StatefulWidget {
  const DdIrcApp({super.key, required this.settings, required this.profiles});

  final AppSettings settings;
  final ProfileStore profiles;

  @override
  State<DdIrcApp> createState() => _DdIrcAppState();
}

class _DdIrcAppState extends State<DdIrcApp> {
  late final Workspace _workspace = Workspace(
    profiles: widget.profiles,
    settings: widget.settings,
  );

  @override
  void dispose() {
    // Closes every live connection, so quitting never leaves a socket behind.
    _workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsScope(
      settings: widget.settings,
      child: ProfileScope(
        store: widget.profiles,
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
              // every dialog on the root navigator — sits under the same frame.
              builder: (context, child) =>
                  WindowFrame(child: child ?? const SizedBox.shrink()),
              home: const WorkspaceScreen(),
            ),
          ),
        ),
      ),
    );
  }
}
