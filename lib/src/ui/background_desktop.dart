import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../model/settings.dart';
import '../model/workspace.dart';
import 'background.dart';

/// Menu item keys. Public so a test can name them without reaching inside.
const showItemKey = 'show';
const quitItemKey = 'quit';

/// The tray's menu: a way back in, and a way out.
///
/// Two items and nothing else. Everything the app can do it can do better in
/// its own window, and a tray menu that grows into a second interface is a
/// second interface to keep in step.
Menu backgroundMenu() => Menu(
  items: [
    MenuItem(key: showItemKey, label: 'Show ddIRC'),
    MenuItem.separator(),
    MenuItem(key: quitItemKey, label: 'Quit ddIRC'),
  ],
);

/// Keeping the app running once its window is closed, on desktop.
///
/// There is nothing here to keep alive. The connections live in the Rust core,
/// on its own threads, inside this process — hiding a window does not stop a
/// process, so a hidden window is already a connected one. What is missing is
/// only the two halves of a door: a way to close the window without ending the
/// process, and a way back in afterwards.
///
/// The tray icon is that second half, and it is not decoration. A window that
/// hides leaving nothing on screen is not a backgrounded app, it is a lost
/// one. So the icon goes up with the setting and comes down with it, and there
/// is no arrangement in which the window can hide with no icon to bring it
/// back.
///
/// The setting decides between hiding and quitting. It does not decide whether
/// this class is in charge of closing: it always is, so that quitting through
/// the window's own close button says goodbye to the servers exactly as
/// quitting through the tray does.
class BackgroundPresence
    with TrayListener, WindowListener
    implements BackgroundKeeper {
  BackgroundPresence({required this.settings, required this.workspace});

  final AppSettings settings;

  /// Read for the tooltip, and closed down on the way out.
  final Workspace workspace;

  bool _trayUp = false;
  bool _quitting = false;
  String? _tooltip;

  /// Reentrancy guard. The settings listener is synchronous and the work it
  /// starts is not, so a second change arriving mid-flight is remembered and
  /// run afterwards rather than interleaved with the first.
  bool _busy = false;
  bool _again = false;

  /// Whether the tray icon is currently on screen.
  @visibleForTesting
  bool get trayIsUp => _trayUp;

  @override
  Future<void> start() async {
    windowManager.addListener(this);
    trayManager.addListener(this);
    // Always intercepted, so closing the window is always this class's
    // decision rather than sometimes its and sometimes the platform's. Which
    // of the two things it then does is the setting's business, not this
    // flag's — and it is what lets a plain close still send a QUIT.
    await windowManager.setPreventClose(true);
    settings.addListener(_onSettingsChanged);
    workspace.addListener(_onConnectionsChanged);
    await _sync();
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    workspace.removeListener(_onConnectionsChanged);
    windowManager.removeListener(this);
    trayManager.removeListener(this);
  }

  /// Bring the window back, from hidden or from minimised.
  ///
  /// Both, because they are different states and only one of them is ours: a
  /// window the user minimised and then clicked the tray for would otherwise
  /// be shown while still minimised, which looks exactly like the click having
  /// done nothing.
  Future<void> show() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// Close the connections, then the app.
  ///
  /// The order is the point. Servers are told first, so everyone in the
  /// channel sees a quit now rather than a ping timeout in two minutes' time,
  /// and only then is the window destroyed.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      workspace.closeAll();
      if (_trayUp) {
        await trayManager.destroy();
        _trayUp = false;
      }
      await Future<void>.delayed(quitGrace);
    } catch (e) {
      debugPrint('could not close down cleanly: $e');
    } finally {
      // Whatever happened above, the user asked to leave. A window left
      // unclosable because a goodbye failed would be the worse bug by far.
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    }
  }

  // ------------------------------------------------------------- the tray

  void _onSettingsChanged() => unawaited(_sync());

  void _onConnectionsChanged() {
    if (!_trayUp || _quitting) return;
    unawaited(_refreshTooltip());
  }

  Future<void> _sync() async {
    if (_quitting) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        await _apply();
      } while (_again);
    } catch (e) {
      debugPrint('could not update the tray: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _apply() async {
    final wanted = settings.runInBackground;
    if (wanted && !_trayUp) {
      await trayManager.setIcon(_iconAsset, isTemplate: _iconIsTemplate);
      await trayManager.setContextMenu(backgroundMenu());
      _trayUp = true;
      // The icon is new, so whatever the tooltip last said was said to a
      // different icon and has to be said again.
      _tooltip = null;
    } else if (!wanted && _trayUp) {
      await trayManager.destroy();
      _trayUp = false;
      _tooltip = null;
    }
    if (_trayUp) await _refreshTooltip();
  }

  Future<void> _refreshTooltip() async {
    final text = trayTooltip(workspace.sessions.length);
    if (text == _tooltip) return;
    _tooltip = text;
    await trayManager.setToolTip(text);
  }

  /// Windows and Linux show the mark as it appears everywhere else — the tray
  /// icon sits beside the taskbar button and should be the same thing. macOS
  /// gets a template, which the menu bar recolours for itself.
  String get _iconAsset => switch (defaultTargetPlatform) {
    TargetPlatform.windows => 'assets/tray/tray.ico',
    TargetPlatform.macOS => 'assets/tray/tray_template.png',
    _ => 'assets/tray/tray.png',
  };

  bool get _iconIsTemplate => defaultTargetPlatform == TargetPlatform.macOS;

  // --------------------------------------------------------- the listeners

  @override
  void onWindowClose() {
    switch (closeAction(
      runInBackground: settings.runInBackground,
      quitting: _quitting,
    )) {
      case CloseAction.hide:
        unawaited(windowManager.hide());
      case CloseAction.quit:
        unawaited(quit());
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Left click restores on Windows and Linux, where the menu belongs on the
    // right button. The macOS menu bar has no right-button convention: a click
    // there opens the menu, and opening the menu is all it does.
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      unawaited(trayManager.popUpContextMenu());
    } else {
      unawaited(show());
    }
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case showItemKey:
        unawaited(show());
      case quitItemKey:
        unawaited(quit());
    }
  }
}
