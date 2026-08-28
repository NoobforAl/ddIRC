import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../model/settings.dart';
import '../model/workspace.dart';
import 'background.dart';

/// The channel [ForegroundService] speaks over. See `MainActivity.kt`.
const backgroundChannel = MethodChannel('dev.ddirc/background');

/// Host-to-Dart calls on [backgroundChannel], fanned out to everyone listening.
///
/// A [MethodChannel] has exactly one handler, and there are now two things that
/// want to hear from the host on this one: the foreground service, which is
/// told to quit, and the notifier, which is told a notification was tapped.
/// Whichever called `setMethodCallHandler` second would silently replace the
/// first — a failure that would look like one feature working perfectly until
/// the other was switched on, which is the worst shape a bug can have.
final androidHostCalls = HostCallDispatcher(backgroundChannel);

/// The dispatcher for [channel], one per channel name.
///
/// Exists because both classes that speak to the host take their channel as a
/// parameter so a test can inject one, and two of them sharing an injected
/// channel must share its dispatcher for the same reason they share the real
/// one. Keyed by name rather than by identity: `MethodChannel` is const, and
/// two `const MethodChannel('x')` are the same channel whether or not they are
/// the same object.
final Map<String, HostCallDispatcher> _dispatchers = {
  backgroundChannel.name: androidHostCalls,
};

HostCallDispatcher hostCallsFor(MethodChannel channel) =>
    _dispatchers.putIfAbsent(channel.name, () => HostCallDispatcher(channel));

/// Lets more than one thing listen to a channel that allows one handler.
class HostCallDispatcher {
  HostCallDispatcher(this._channel);

  final MethodChannel _channel;
  final List<Future<dynamic> Function(MethodCall)> _handlers = [];

  /// Registered lazily and torn down again when the last one goes, so a
  /// platform channel is never left with a handler that answers nothing.
  void add(Future<dynamic> Function(MethodCall) handler) {
    if (_handlers.isEmpty) _channel.setMethodCallHandler(_dispatch);
    _handlers.add(handler);
  }

  void remove(Future<dynamic> Function(MethodCall) handler) {
    _handlers.remove(handler);
    if (_handlers.isEmpty) _channel.setMethodCallHandler(null);
  }

  /// Every handler sees every call; the first non-null answer is the answer.
  ///
  /// Handlers are expected to ignore what is not theirs and return null, which
  /// makes "nobody handled it" and "handled, nothing to say" the same result —
  /// correct here, because the host asks for no return value.
  Future<dynamic> _dispatch(MethodCall call) async {
    for (final handler in List.of(_handlers)) {
      final result = await handler(call);
      if (result != null) return result;
    }
    return null;
  }
}

/// Staying connected on Android, where the process is not ours to keep.
///
/// Nothing here holds a connection. As on desktop, the connections live in the
/// Rust core on its own threads inside this process, and they run for exactly
/// as long as the process does. The difference is what happens to the process.
/// An app the user is not looking at is a cached process, and a cached process
/// is the first thing Android kills when memory runs short — so on Android the
/// thing that has to be arranged is not a window that refuses to close, but
/// permission to go on existing at all.
///
/// A foreground service is how that permission is asked for, and the price
/// Android charges is a notification the user can see. That price is worth
/// naming rather than hiding: an app that keeps a socket open while you are
/// not looking at it *should* be visible, and the notification doubles as the
/// same reassurance the tray icon gives on desktop.
///
/// Deliberately not held past a swipe from Recents. That gesture means "close
/// this", the service honours it, and the setting says so in as many words —
/// see [backgroundSettingDescription]. Surviving it would need the Flutter
/// engine cached outside the activity, and an app the user cannot dismiss is
/// not the feature that was asked for.
class ForegroundService implements BackgroundKeeper {
  ForegroundService({
    required this.settings,
    required this.workspace,
    this.channel = backgroundChannel,
  });

  final AppSettings settings;

  /// Read for the notification, and closed down on the way out.
  final Workspace workspace;

  /// Overridable so a test can watch what is asked of the host without an
  /// Android to ask.
  final MethodChannel channel;

  bool _running = false;
  bool _quitting = false;
  String? _status;

  /// Reentrancy guard, as on desktop: the settings listener is synchronous and
  /// the work it starts is not.
  bool _busy = false;
  bool _again = false;

  /// Whether the service is currently up.
  @visibleForTesting
  bool get serviceIsRunning => _running;

  @override
  Future<void> start() async {
    hostCallsFor(channel).add(_onHostCall);
    settings.addListener(_onSettingsChanged);
    workspace.addListener(_onConnectionsChanged);
    await _sync();
  }

  @override
  void dispose() {
    settings.removeListener(_onSettingsChanged);
    workspace.removeListener(_onConnectionsChanged);
    hostCallsFor(channel).remove(_onHostCall);
  }

  /// The notification's Quit button, or a swipe from Recents.
  ///
  /// The order is the same as desktop's, and for the same reason: the servers
  /// are told first, so everyone in the channel sees a quit now rather than a
  /// ping timeout in two minutes' time.
  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    try {
      workspace.closeAll();
      await Future<void>.delayed(quitGrace);
    } catch (e) {
      debugPrint('could not close down cleanly: $e');
    } finally {
      await _invoke('stop');
      _running = false;
      // Finishes the activity. The process is then an ordinary cached one and
      // is reclaimed in Android's own time, which is the platform's business
      // rather than ours to force.
      await SystemNavigator.pop();
    }
  }

  Future<dynamic> _onHostCall(MethodCall call) async {
    if (call.method == 'quit') await quit();
    return null;
  }

  // --------------------------------------------------------- the service

  void _onSettingsChanged() => unawaited(_sync());

  void _onConnectionsChanged() {
    if (!_running || _quitting) return;
    unawaited(_refreshStatus());
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
      debugPrint('could not update the background service: $e');
    } finally {
      _busy = false;
    }
  }

  Future<void> _apply() async {
    final wanted = settings.runInBackground;
    if (wanted && !_running) {
      await _askAboutNotifications();
      _status = connectionSummary(workspace.sessions.length);
      await _invoke('start', {'status': _status});
      _running = true;
    } else if (!wanted && _running) {
      await _invoke('stop');
      _running = false;
      _status = null;
    } else if (_running) {
      await _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    final text = connectionSummary(workspace.sessions.length);
    if (text == _status) return;
    _status = text;
    await _invoke('update', {'status': text});
  }

  /// Ask for the notification permission, and carry on either way.
  ///
  /// From Android 13 the notification is a permission of its own, and the
  /// answer does not gate the feature: the service runs whether or not it is
  /// granted, and the connections stay up. What refusing costs is only being
  /// told that it is running — which is the user's call to make, and not a
  /// reason to refuse them the thing they just switched on.
  Future<void> _askAboutNotifications() async {
    final allowed = await _invoke<bool>('notificationsAllowed') ?? true;
    if (allowed) return;
    await _invoke<bool>('requestNotifications');
  }

  /// Every call to the host, in one place, so none of them can bring the app
  /// down.
  ///
  /// A failure here means the app is not staying in the background, which is a
  /// setting not working. It is not worth an exception reaching the user, and
  /// it must never be worth losing the connection that is already up.
  Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await channel.invokeMethod<T>(method, arguments);
    } catch (e) {
      debugPrint('background service: $method failed ($e)');
      return null;
    }
  }
}
