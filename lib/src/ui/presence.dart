// Whether ddIRC is the thing the user is actually looking at.
//
// Nothing else in the app has ever needed to know this, and notifications turn
// on it entirely: the single worst behaviour a notification can have is firing
// for a message that was already on screen when it arrived.
//
// The awkward part is that "in front" means two different things on the two
// kinds of platform, and the obvious answer is wrong on one of them. On
// Android, `AppLifecycleState` is the whole story. On desktop it is not: a
// window sitting behind a browser is still `resumed`, because the app has not
// been backgrounded in any sense the framework recognises — it is simply not
// the window with focus. Asking only the lifecycle would report the app as in
// front for most of the time it is plainly not.

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'background.dart' show keepsRunningInBackground;

/// The rule, separated so it can be read and tested without either platform.
///
/// [windowFocused] is null where the question does not apply — Android has no
/// window to focus — and the lifecycle state answers alone. Where it does
/// apply, both have to be true: a focused window in a paused app is not a
/// thing, but an unfocused window in a resumed app is the normal state of a
/// desktop app nobody is using.
bool isInForeground(AppLifecycleState state, {bool? windowFocused}) {
  if (state != AppLifecycleState.resumed) return false;
  return windowFocused ?? true;
}

/// Tracks whether the app is in front, and says when the answer changes.
///
/// A [ChangeNotifier] rather than something read on demand, because the
/// interesting moment is the transition: what is read on every message is
/// [inForeground], and what a listener wants to know is when it became false.
class AppPresence extends ChangeNotifier
    with WidgetsBindingObserver, WindowListener {
  AppPresence({@visibleForTesting bool? watchesWindow})
    : _watchesWindow =
          watchesWindow ?? (!kIsWeb && keepsRunningInBackground && _isDesktop);

  static bool get _isDesktop => const {
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  }.contains(defaultTargetPlatform);

  /// Whether this platform has a window whose focus is worth asking about.
  final bool _watchesWindow;

  AppLifecycleState _state = AppLifecycleState.resumed;

  /// Assumed true until told otherwise.
  ///
  /// The app starts in front — it was just launched — and a first value of
  /// false would notify for the first message to arrive before the window
  /// manager had said anything, which is the failure this whole file exists to
  /// avoid.
  bool _focused = true;

  bool get inForeground =>
      isInForeground(_state, windowFocused: _watchesWindow ? _focused : null);

  void start() {
    WidgetsBinding.instance.addObserver(this);
    if (_watchesWindow) windowManager.addListener(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_watchesWindow) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _update(() => _state = state);
  }

  // Minimising is listened for as well as blurring because it is not
  // guaranteed to be accompanied by one, and a minimised window that still
  // believes it has focus is a window that swallows every notification.
  //
  // Hiding to the tray needs no case of its own: the window is deactivated on
  // its way out, which arrives here as a blur. `WindowListener` has no
  // `onWindowHide` to override in any event.
  @override
  void onWindowFocus() => _update(() => _focused = true);

  @override
  void onWindowRestore() => _update(() => _focused = true);

  @override
  void onWindowBlur() => _update(() => _focused = false);

  @override
  void onWindowMinimize() => _update(() => _focused = false);

  void _update(VoidCallback change) {
    final before = inForeground;
    change();
    if (inForeground != before) notifyListeners();
  }

  /// Drive the state directly, for tests that have neither a window nor a
  /// lifecycle to change.
  @visibleForTesting
  void setForTesting({AppLifecycleState? state, bool? focused}) {
    _update(() {
      if (state != null) _state = state;
      if (focused != null) _focused = focused;
    });
  }
}
