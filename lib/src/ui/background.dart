import 'package:flutter/foundation.dart';

import '../model/settings.dart';
import '../model/workspace.dart';
import 'background_android.dart';
import 'background_desktop.dart';

/// Whether closing the window can leave the app running on [platform].
///
/// Two platforms, and they mean it differently enough that the mechanisms have
/// nothing in common. On desktop the process simply keeps running once the
/// window is hidden, and all that is needed is a way back to it. On Android
/// the process belongs to the system, and staying alive has to be asked for
/// with a foreground service and paid for with a notification.
///
/// iOS is the one exclusion. It will not hold a TCP socket open for an app
/// that is not in front, so a switch offering it would be a promise the
/// platform refuses to keep — and a control that cannot keep its promise is
/// worse than no control.
///
/// Takes the platform rather than reading it, so the rule can be asked about
/// every platform from a test that only runs as one of them.
bool runsInBackgroundOn(TargetPlatform platform) => const {
  TargetPlatform.windows,
  TargetPlatform.linux,
  TargetPlatform.macOS,
  TargetPlatform.android,
}.contains(platform);

/// [runsInBackgroundOn] for the platform this build is running on.
///
/// Deliberately its own constant rather than a reuse of `hasWindowChrome`. The
/// two named the same three platforms once and mean entirely different things,
/// which this now demonstrates: Android is here and has no window chrome at
/// all.
final bool keepsRunningInBackground =
    !kIsWeb && runsInBackgroundOn(defaultTargetPlatform);

/// What closing the window should do. Desktop only; Android has no such event.
enum CloseAction { hide, quit }

/// The one decision behind the close button, separated so it can be read.
///
/// [quitting] is what stops the second pass: quitting tears the window down,
/// which arrives back here as another close, and without this the app would
/// hide itself instead of leaving.
CloseAction closeAction({
  required bool runInBackground,
  required bool quitting,
}) => runInBackground && !quitting ? CloseAction.hide : CloseAction.quit;

/// How many networks are up, in the words shown when the app is out of sight.
///
/// One sentence for both platforms, because it answers the same question in
/// both places — the tray tooltip on desktop, the notification on Android —
/// and two wordings that drifted apart would be two things to keep true.
///
/// "Not connected" is stated as plainly as a count. Something that mentions
/// connections only when it has some says nothing by its silence, and
/// believing you are still on a network when you are not is the failure worth
/// catching.
String connectionSummary(int networks) => switch (networks) {
  0 => 'not connected',
  1 => '1 network connected',
  _ => '$networks networks connected',
};

/// The tray icon's tooltip.
///
/// Named here, because a tooltip stands alone and has to say which app it
/// belongs to; the Android notification carries the app's name in its title
/// already and would only repeat itself.
String trayTooltip(int networks) => 'ddIRC — ${connectionSummary(networks)}';

/// How long the servers get to hear the goodbye.
///
/// A bounded courtesy, not a guarantee. The QUIT has already been handed to
/// the core by the time this starts; this is only the moment it needs to reach
/// the wire before the process stops existing. Long enough for that, short
/// enough that nobody reads it as the app hesitating.
const quitGrace = Duration(milliseconds: 250);

/// What the setting says it will do, which is not the same thing twice.
///
/// The promise is identical — stay connected while you are elsewhere — but
/// what the user will see, and what will end it, are different enough on each
/// platform that one wording would have to be vague to cover both.
String backgroundSettingDescription(TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.android =>
        'ddIRC keeps its connections while you are in another app, with a '
            'notification to say so. Swiping it away from Recents still '
            'closes it.',
      _ =>
        'Closing the window hides it to the tray instead of quitting, so the '
            'connections stay up and nothing is missed while it is away. The '
            'tray icon brings it back, and is also how you quit for real.',
    };

/// Keeps the app running while it is not the thing in front.
///
/// Two implementations that share no mechanism at all, which is the reason
/// this is an interface rather than one class with a platform switch inside
/// it. What they do share — the setting, the wording, the closing of
/// connections on the way out — lives in this file instead.
abstract interface class BackgroundKeeper {
  /// Begin watching the setting. Safe to call once, at startup.
  Future<void> start();

  void dispose();
}

/// The right [BackgroundKeeper] for this platform, or one that does nothing.
///
/// Construction is the only place the platform is decided. Neither
/// implementation checks again, because a class that has been built is a class
/// on the platform it was built for.
BackgroundKeeper backgroundKeeperFor({
  required AppSettings settings,
  required Workspace workspace,
}) {
  if (kIsWeb) return const NoBackgroundKeeper();
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows || TargetPlatform.linux || TargetPlatform.macOS =>
      BackgroundPresence(settings: settings, workspace: workspace),
    TargetPlatform.android => ForegroundService(
      settings: settings,
      workspace: workspace,
    ),
    _ => const NoBackgroundKeeper(),
  };
}

/// iOS, and anywhere else that cannot honestly offer this.
///
/// A real object rather than a null, so nothing above has to remember that
/// this is sometimes absent.
class NoBackgroundKeeper implements BackgroundKeeper {
  const NoBackgroundKeeper();

  @override
  Future<void> start() async {}

  @override
  void dispose() {}
}
