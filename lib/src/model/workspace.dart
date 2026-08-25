import 'dart:async';

import 'package:flutter/widgets.dart';

import '../rust/api/client.dart' as core;
import 'errors.dart';
import 'log.dart';
import 'profile.dart';
import 'proxy.dart';
import 'session.dart';
import 'settings.dart';

/// Every network the user is connected to at once.
///
/// The Rust core already keys connections by id and runs each in its own actor,
/// so several at a time costs nothing structurally — this class is only the
/// bookkeeping the UI needs: which profiles are live, which one is in front,
/// and how much unread each is holding.
class Workspace extends ChangeNotifier {
  Workspace({
    required this.profiles,
    required this.settings,
    required this.proxies,
  });

  final ProfileStore profiles;
  final AppSettings settings;

  /// The app-wide proxy. Read at connect time rather than held, so changing it
  /// applies to the next connection without needing to touch live ones.
  final ProxySettings proxies;

  final Map<String, SessionModel> _sessions = {};
  final Map<String, String> _failures = {};
  final Set<String> _connecting = {};
  String? _active;
  bool _startedAutomatic = false;
  bool _closed = false;

  /// Live sessions, in the order their profiles are saved, so the rail does
  /// not reshuffle as connections come and go.
  List<SessionModel> get sessions => [
    for (final profile in profiles.profiles)
      if (_sessions[profile.id] != null) _sessions[profile.id]!,
  ];

  SessionModel? get active => _active == null ? null : _sessions[_active];
  String? get activeProfileId => _active;

  SessionModel? sessionFor(String profileId) => _sessions[profileId];
  bool isConnecting(String profileId) => _connecting.contains(profileId);
  bool isConnected(String profileId) => _sessions.containsKey(profileId);

  /// Why the last connection attempt for this profile failed, if it did.
  String? failureFor(String profileId) => _failures[profileId];

  int unreadFor(String profileId) => _sessions[profileId]?.totalUnread ?? 0;

  int mentionsFor(String profileId) => _sessions[profileId]?.totalMentions ?? 0;

  void select(String profileId) {
    if (!_sessions.containsKey(profileId)) return;
    _active = profileId;
    notifyListeners();
  }

  /// Connect every profile marked to connect at launch.
  ///
  /// All at once and none of them awaited: a network that is slow or refusing
  /// connections must not hold up the others, and none of them may hold up the
  /// first frame. Failures land in [failureFor] like any other, so a server
  /// that is down at launch is reported where the user would look anyway
  /// rather than interrupting a startup they did not ask to be part of.
  ///
  /// Which network you land on is decided here rather than by whichever
  /// connection wins the race — otherwise the window you open into would
  /// depend on how fast each server answered that morning. The first marked
  /// profile in saved order takes the selection; if it fails, whichever else
  /// arrives first is shown, so a launch that connected *something* never
  /// lands on an empty screen.
  ///
  /// Runs once per launch, however many times it is called.
  Future<void> connectAutomatic() async {
    if (_startedAutomatic) return;
    _startedAutomatic = true;

    final marked = automatic;
    if (marked.isEmpty) return;

    for (final profile in marked) {
      unawaited(connect(profile, focus: profile.id == marked.first.id));
    }
  }

  /// The profiles [connectAutomatic] will open, in the order it opens them.
  ///
  /// Separated so the ordering — the part with a decision in it — can be
  /// tested. The connecting itself crosses the FFI and cannot run in a widget
  /// test.
  @visibleForTesting
  List<Profile> get automatic => [
    for (final profile in profiles.profiles)
      if (profile.autoConnect) profile,
  ];

  /// Whether [connectAutomatic] has already run this launch.
  @visibleForTesting
  bool get startedAutomatic => _startedAutomatic;

  /// Connect a saved profile, or bring it to the front if it is already up.
  ///
  /// Returns an error to show inline, or null on success.
  ///
  /// `focus` is false only for connections the user did not just ask for — the
  /// ones made on their behalf at launch. Those still take the selection when
  /// nothing else holds it.
  Future<String?> connect(Profile profile, {bool focus = true}) async {
    if (_sessions.containsKey(profile.id)) {
      select(profile.id);
      return null;
    }
    if (_connecting.contains(profile.id)) return null;

    _connecting.add(profile.id);
    _failures.remove(profile.id);
    notifyListeners();

    try {
      // Read the password here and hand it straight to the core, which
      // zeroizes it after SASL. It is never held on the profile.
      final password = profile.usesSasl
          ? await profiles.passwordFor(profile.id)
          : null;
      // Settled here, once, rather than inside the core: the choice between
      // the app-wide proxy and this server's own is the app's to make, and
      // the core is better off being handed an answer.
      final proxy = await resolveProxy(profile, proxies, profiles);
      final config = profile.toConfig(saslPassword: password, proxy: proxy);
      if (proxy != null) {
        AppLog.instance.debug(
          '[${profile.host}] connecting through SOCKS5 '
          '${proxy.host}:${proxy.port}',
        );
      }
      final id = await core.connect(config: config);

      final session = SessionModel(
        connectionId: id,
        profileId: profile.id,
        config: config,
        settings: settings,
      )..start();
      // One listener per session, forwarded so the whole workspace repaints
      // when any network has news — that is what the rail badges read.
      session.addListener(notifyListeners);

      _sessions[profile.id] = session;
      if (focus || _active == null) _active = profile.id;
      return null;
    } catch (e) {
      final message = describeError(e);
      _failures[profile.id] = message;
      AppLog.instance.debug('[${profile.host}] could not connect: $message');
      return message;
    } finally {
      _connecting.remove(profile.id);
      notifyListeners();
    }
  }

  /// Disconnect one network and close its conversations.
  void disconnect(String profileId) {
    final session = _sessions.remove(profileId);
    if (session == null) return;
    session.removeListener(notifyListeners);
    session.dispose();

    if (_active == profileId) {
      // Fall back to whatever else is still connected, so disconnecting one
      // network never leaves the user staring at nothing while others are up.
      _active = _sessions.keys.isEmpty ? null : _sessions.keys.last;
    }
    notifyListeners();
  }

  /// Stop waiting out the backoff and try again now.
  ///
  /// This used to tear the connection down and build a new one, because the
  /// core had no way to be told to hurry. That worked, but it threw the
  /// scrollback away every time — the user pressed retry and lost the
  /// conversation they were retrying to get back to.
  ///
  /// The core now takes a reconnect command, so the actor counting down is
  /// woken in place and everything it holds survives. A profile with no live
  /// session still falls back to dialling from scratch: there is no actor to
  /// wake, which is the case after a fatal error stopped the connection for
  /// good.
  Future<String?> reconnect(Profile profile) async {
    final session = _sessions[profile.id];
    if (session == null) return connect(profile);
    await session.retryNow();
    return null;
  }

  /// Called when a profile is deleted: its connection must not outlive it.
  void forget(String profileId) {
    disconnect(profileId);
    _failures.remove(profileId);
  }

  /// Close every live connection, telling each server why.
  ///
  /// Separate from [dispose], and safe to call twice, because quitting closes
  /// the connections first and tears the window down second — and the teardown
  /// runs the widget tree's own dispose on its way out, which arrives back
  /// here. Disposing a [ChangeNotifier] twice throws; saying goodbye twice
  /// should not.
  void closeAll() {
    if (_closed) return;
    _closed = true;
    for (final session in _sessions.values) {
      session.removeListener(notifyListeners);
      // Sends a QUIT, so the servers hear it from us rather than finding out
      // when the socket dies two minutes later.
      session.dispose();
    }
    _sessions.clear();
  }

  @override
  void dispose() {
    closeAll();
    super.dispose();
  }
}

/// Makes the [Workspace] available to the widget tree.
class WorkspaceScope extends InheritedNotifier<Workspace> {
  const WorkspaceScope({
    super.key,
    required Workspace workspace,
    required super.child,
  }) : super(notifier: workspace);

  static Workspace of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<WorkspaceScope>();
    assert(scope?.notifier != null, 'No WorkspaceScope above this widget');
    return scope!.notifier!;
  }
}
