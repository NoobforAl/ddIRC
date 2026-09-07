import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../model/app_lock.dart';
import '../../model/local_server.dart';
import '../../model/log.dart';
import '../../model/proxy.dart';
import '../../model/settings.dart';
import '../../version.dart';
import '../background.dart';
import '../motion.dart';
import '../notifier.dart' show notificationHelpFor, notificationsSupportedOn;
import 'app_lock_section.dart';
import 'file_transfer_section.dart';
import 'local_server_section.dart';
import 'message_history_section.dart';
import 'proxy_section.dart';
import 'settings_chrome.dart';
import 'tor_section.dart';

/// The section heading, which is not "Window" on a phone.
String get _backgroundSectionLabel =>
    defaultTargetPlatform == TargetPlatform.android ? 'Background' : 'Window';

/// Named for the gesture that triggers it, which differs by platform: a
/// desktop user closes a window, a phone user simply goes somewhere else.
String get _backgroundSwitchLabel =>
    defaultTargetPlatform == TargetPlatform.android
    ? 'Stay connected in the background'
    : 'Keep running when the window is closed';

/// The pages of app settings.
///
/// Naming them in an enum rather than building the lists inline is what makes
/// the index and the page the same decision: a page cannot be reachable from
/// the index and then turn out not to exist, and a new one cannot be added
/// without a summary line, because the enum requires it.
///
/// # Why there are four
///
/// Connection used to hold six sections and was half again as long as the
/// other two put together. What gave away where to cut it was its own summary
/// line: it has always read "Built-in Tor · local server on · file transfers
/// on" and has never once mentioned staying connected or notifications —
/// because those are not what the page was about. They had been put there
/// because they were connection-adjacent, not because anybody would look for
/// them under it.
///
/// So the routing sections keep the page and the name, and the two that answer
/// "what happens while I am somewhere else" get their own. That page is called
/// Notifications, which is the half of it people go looking for by name; the
/// other half sits at the top of it under its own heading, and the index row
/// says which way it is set so that nobody has to open the page to find out.
enum _Page {
  appearance('Appearance', 'How the app looks and how much it says'),
  connection('Connection', 'How and where ddIRC connects'),
  notifications(
    'Notifications',
    'Staying connected while you are elsewhere, and hearing about it',
  ),
  privacy('Privacy', 'What is written down, and what is always on');

  const _Page(this.label, this.subtitle);

  final String label;

  /// Shown under the page's own title once it is open. Says what the page is
  /// for, where the index row says what is currently set in it.
  final String subtitle;
}

/// Preferences that apply everywhere, on every server.
///
/// An index and four pages, rather than a dozen sections in one column. The
/// dialog reached the length where scrolling was how you found anything, and
/// everything looking equally important is the same as nothing being
/// findable — someone looking for the proxy had to read past the timestamps to
/// be sure they had not gone by it.
///
/// One level of nesting, and no more. A page here opens in place rather than
/// on top, so there is never a dialog over a dialog, and every page is one
/// press from the index and two from anywhere — which is the depth at which a
/// menu is still faster than the long list it replaced.
///
/// The cost of a menu is that the state is no longer all on screen at once,
/// and it is paid back on the index itself: every row carries what is
/// currently set inside it, so "am I going through Tor" is still answered
/// without opening anything.
///
/// Each change takes effect immediately and writes through to disk. The one
/// exception is the proxy, which is a typed address rather than a switch and
/// so has a state that is neither the old value nor a working new one; it
/// carries its own buttons and explains why.
class AppSettingsDialog extends StatefulWidget {
  const AppSettingsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const AppSettingsDialog(),
    );
  }

  @override
  State<AppSettingsDialog> createState() => _AppSettingsDialogState();
}

class _AppSettingsDialogState extends State<AppSettingsDialog> {
  /// Null on the index.
  _Page? _page;

  void _open(_Page page) => setState(() => _page = page);
  void _back() => setState(() => _page = null);

  @override
  Widget build(BuildContext context) {
    final page = _page;
    final m = context.motion;

    final body = Column(
      key: ValueKey(page),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: switch (page) {
        null => _index(context),
        _Page.appearance => _appearance(context),
        _Page.connection => _connection(context),
        _Page.notifications => _notifications(context),
        _Page.privacy => _privacy(context),
      },
    );

    return SettingsDialog(
      title: page?.label ?? 'App settings',
      subtitle: page?.subtitle ?? 'Applies to every server',
      onBack: page == null ? null : _back,
      children: [
        // Stepped out of the way entirely with motion off, not merely given a
        // zero duration. `AnimatedSize` restarts its controller from inside
        // its own `performLayout`, and a zero duration finishes that
        // synchronously, which re-dirties the render object mid-layout and
        // trips an assertion. `Reveal` documents the same trap.
        if (m.disabled)
          body
        else
          // Sized as well as switched, and only where the dialog is a card
          // that grows to fit: the pages are very different heights, and one
          // that jumped from the index straight to the full height of
          // Connection would move the back arrow out from under the pointer
          // that just arrived on it. Full bleed, the frame is already the
          // screen and there is nothing to animate.
          AnimatedSize(
            duration: m.normal,
            curve: Motion.curve,
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: m.fast,
              // Cross-fade in place, with nothing sliding. A settings page is
              // read, not navigated through, and text in motion is unreadable
              // for as long as it moves.
              child: body,
            ),
          ),
        const SizedBox(height: 10),
      ],
    );
  }

  // ---------------------------------------------------------------- the index

  List<Widget> _index(BuildContext context) {
    final settings = SettingsScope.of(context);
    final proxies = ProxyScope.of(context);
    final server = LocalServerScope.of(context);

    return [
      const SizedBox(height: 4),
      SettingsNavRow(
        label: _Page.appearance.label,
        summary:
            '${settings.themeMode.label} · ${settings.density.label} · '
            '${settings.showTimestamps ? 'timestamps on' : 'no timestamps'}',
        onTap: () => _open(_Page.appearance),
      ),
      const SettingsRule(),
      SettingsNavRow(
        label: _Page.connection.label,
        summary: _connectionSummary(proxies, server, settings),
        // Two of the four sections behind this row are beta, and the badge is
        // on the row because the point of it is to be seen before the feature
        // is reached rather than after.
        beta: true,
        onTap: () => _open(_Page.connection),
      ),
      if (_hasNotificationSettings) ...[
        const SettingsRule(),
        SettingsNavRow(
          label: _Page.notifications.label,
          summary: _notificationSummary(settings),
          onTap: () => _open(_Page.notifications),
        ),
      ],
      const SettingsRule(),
      SettingsNavRow(
        label: _Page.privacy.label,
        summary: _privacySummary(settings, AppLockScope.of(context)),
        onTap: () => _open(_Page.privacy),
      ),
      const SettingsRule(),
      const SizedBox(height: 10),
      // The empty screen says this too, but it is only reachable with nothing
      // connected — which is not where anybody spends their time. Settings is
      // the one surface that is always one click away.
      const SettingsNote(
        text:
            '$appVersionLabel. It connects and it works, but it has not been '
            'through a security review and it has not been run by many '
            'people. Treat it the way you would treat any client you had just '
            'compiled yourself.',
      ),
    ];
  }

  /// What the Connection page is currently holding, in a few words.
  ///
  /// The route comes first and is never omitted, because "direct" is an answer
  /// and a summary that mentioned a proxy only when there was one would say
  /// nothing by its silence — and believing you are proxied when you are not
  /// is the failure worth catching.
  static String _connectionSummary(
    ProxySettings proxies,
    LocalServerSettings server,
    AppSettings settings,
  ) {
    final route = switch (proxies.route) {
      ProxyRoute.builtIn =>
        proxies.waiting ? 'Built-in Tor (starting)' : 'Built-in Tor',
      ProxyRoute.manual => proxies.endpoint?.label ?? 'Own proxy',
      ProxyRoute.off => 'Direct',
    };
    return [
      route,
      if (server.running) 'local server on',
      if (settings.fileTransfers) 'file transfers on',
    ].join(' · ');
  }

  /// Whether the Notifications page has anything on it.
  ///
  /// Both of its sections are absent on iOS, and a row leading to an empty
  /// page is worse than no row: it promises a setting the platform will not
  /// let this app have. Asked as "either", not "the one that happens to be
  /// equivalent today", so that the two lists diverging does not silently
  /// bring back the empty page.
  static bool get _hasNotificationSettings =>
      keepsRunningInBackground ||
      notificationsSupportedOn(defaultTargetPlatform);

  /// What the Notifications page is currently holding.
  ///
  /// Staying connected comes first and is stated either way, for the reason
  /// the route is on the Connection row: it is the half of this page the label
  /// does not advertise, so this is where somebody checking whether ddIRC
  /// survives being put away gets their answer — and a summary that mentioned
  /// it only when it was on would say nothing by its silence.
  static String _notificationSummary(AppSettings settings) {
    return [
      if (keepsRunningInBackground)
        settings.runInBackground
            ? 'Staying connected'
            : 'Not staying connected',
      if (notificationsSupportedOn(defaultTargetPlatform))
        settings.notifications ? 'messages on' : 'messages off',
    ].join(' · ');
  }

  static String _privacySummary(AppSettings settings, AppLockSettings lock) {
    final logs = [
      if (settings.saveChatLogs) 'chat logs',
      if (settings.saveDebugLogs) 'debug logs',
      // Named on the index row for the same reason the logs are: this row
      // exists so somebody can see what is being written down without opening
      // anything, and a database of conversations is the largest of the three.
      if (settings.saveMessages) 'message history',
    ];
    // Written out as a list a person would say aloud. With three of these
    // possible, `join(' and ')` produced "a and b and c".
    final writing = switch (logs.length) {
      0 => 'Nothing written to disk',
      1 => 'Saving ${logs.single}',
      _ =>
        'Saving ${logs.sublist(0, logs.length - 1).join(', ')} '
            'and ${logs.last}',
    };
    return lock.enabled ? 'App lock on · $writing' : writing;
  }

  // ----------------------------------------------------------------- the pages

  List<Widget> _appearance(BuildContext context) {
    final settings = SettingsScope.of(context);
    return [
      SettingsSection(
        label: 'Theme',
        children: [
          SettingsChoice<ThemeMode>(
            label: 'Theme',
            options: ThemeMode.values,
            labelFor: (m) => m.label,
            value: settings.themeMode,
            onChanged: (v) => settings.themeMode = v,
          ),
          SettingsChoice<Density>(
            label: 'Density',
            options: Density.values,
            labelFor: (d) => d.label,
            value: settings.density,
            onChanged: (v) => settings.density = v,
          ),
        ],
      ),
      SettingsSection(
        label: 'Messages',
        children: [
          SettingsSwitch(
            label: 'Show timestamps',
            description:
                'Stamped when the message arrives — IRC only carries '
                'a time of its own on servers that support it.',
            value: settings.showTimestamps,
            onChanged: (v) => settings.showTimestamps = v,
          ),
          SettingsSwitch(
            label: '24-hour clock',
            value: settings.twentyFourHour,
            onChanged: (v) => settings.twentyFourHour = v,
          ),
        ],
      ),
      SettingsSection(
        label: 'Noise',
        children: [
          SettingsSwitch(
            label: 'Show joins, parts and quits',
            description:
                'Hiding them keeps a busy channel readable. Topic '
                'and connection notices are always shown.',
            value: settings.showSystemMessages,
            onChanged: (v) => settings.showSystemMessages = v,
          ),
          SettingsSwitch(
            label: 'Render mIRC colours',
            description:
                'Colours chosen by other people. Unreadable ones are '
                'already corrected; turn this off to ignore them '
                'entirely.',
            value: settings.renderColors,
            onChanged: (v) => settings.renderColors = v,
          ),
        ],
      ),
    ];
  }

  List<Widget> _connection(BuildContext context) {
    return const [
      // Ordered by how far the connection travels: a server on this machine,
      // then Tor, then somewhere the user runs themselves.
      LocalServerSection(),
      TorSection(),
      GlobalProxySection(),
      // Last, because it is the one that does not go through any of the three
      // above — which is the thing about it worth noticing.
      FileTransferSection(),
    ];
  }

  List<Widget> _notifications(BuildContext context) {
    final settings = SettingsScope.of(context);
    return [
      // First, and above the switch the page is named after, because it is the
      // one that decides whether there is anything to notify about. Notifying
      // is what happens when a message arrives while you are elsewhere; this
      // is whether the app is still there to receive one.
      //
      // Absent on iOS rather than shown and disabled: the OS will not hold a
      // socket open for an app that is not in front, so the switch would be a
      // promise the platform refuses to keep, and a control that cannot keep
      // its promise is worse than no control.
      if (keepsRunningInBackground)
        SettingsSection(
          label: _backgroundSectionLabel,
          children: [
            SettingsSwitch(
              label: _backgroundSwitchLabel,
              description: backgroundSettingDescription(defaultTargetPlatform),
              value: settings.runInBackground,
              onChanged: (v) => settings.runInBackground = v,
            ),
          ],
        ),
      // The other half of the same promise: one keeps the socket open while
      // you are elsewhere, and this is how you find out that it caught
      // something.
      if (notificationsSupportedOn(defaultTargetPlatform))
        SettingsSection(
          label: 'Notifications',
          // The one thing this switch cannot do anything about, said where
          // somebody wondering why nothing appears will find it. The operating
          // system has its own switch above this one, ddIRC cannot read it,
          // and a notification refused there is refused silently — which
          // leaves this page claiming notifications are on while nothing is
          // ever drawn.
          help: notificationHelpFor(defaultTargetPlatform),
          children: [
            SettingsSwitch(
              label: 'Notify me about messages',
              description:
                  'A direct message, or your nickname in a channel, while '
                  'ddIRC is not the window in front. Never ordinary channel '
                  'traffic — a per-channel setting can quieten it further.',
              value: settings.notifications,
              onChanged: (v) => settings.notifications = v,
            ),
            SettingsSwitch(
              label: 'Show the message in the notification',
              description:
                  'Off by default. A notification is drawn by the operating '
                  'system and may sit on a lock screen, which puts what was '
                  'said somewhere this app can no longer take it back from.',
              value: settings.notifyPreview,
              onChanged: (v) => settings.notifyPreview = v,
            ),
          ],
        ),
    ];
  }

  List<Widget> _privacy(BuildContext context) {
    final settings = SettingsScope.of(context);
    return [
      // First, because it is the line of defense everything else on this page
      // sits behind. Not shown on Linux: local_auth has no implementation
      // there, and a switch that could not do anything is worse than no
      // switch.
      if (appLockSupportedOn(defaultTargetPlatform)) ...[
        const AppLockSection(),
        const SettingsRule(),
      ],
      SettingsSection(
        label: 'Logging',
        children: [
          SettingsSwitch(
            label: 'Save chat logs',
            description:
                'Writes what is said to a file, in plain text. This is '
                'the most sensitive thing the app can store — anyone '
                'who can read the folder can read your conversations.',
            value: settings.saveChatLogs,
            onChanged: (v) => settings.saveChatLogs = v,
          ),
          SettingsSwitch(
            label: 'Save debug logs',
            description:
                'Connection and protocol events only, never message '
                'text. Turn this on before reproducing a bug, so the '
                'report can say what actually happened.',
            value: settings.saveDebugLogs,
            onChanged: (v) => settings.saveDebugLogs = v,
          ),
          SettingsReadout(
            label: 'Folder',
            // Shown whether or not either switch is on, so it is possible to
            // know where the files would go before agreeing to them.
            value:
                AppLog.instance.directoryPath ?? 'Unavailable on this platform',
          ),
          const SettingsReadout(
            label: 'Size',
            value: 'Rotated at 10 MB, one previous copy kept',
          ),
        ],
      ),
      // Immediately after the logs, because it is the other switch on this
      // page that writes down what people said and the two should be weighed
      // together.
      const MessageHistorySection(),
      // Beside the log folder, because it answers the same question — where
      // does this end up — and because "are my settings actually saved?" has
      // had no answer in the app short of going and looking for the file.
      SettingsSection(
        label: 'Settings',
        children: [
          FutureBuilder<String>(
            future: settingsFileLocation(),
            builder: (context, snapshot) => SettingsReadout(
              label: 'Stored in',
              value: snapshot.data ?? 'Looking…',
            ),
          ),
          const SettingsReadout(
            label: 'Not stored there',
            // Worth saying in the same breath. Someone reading a settings path
            // is entitled to assume it holds everything, and the one thing it
            // deliberately does not hold is the thing that would matter most.
            value: 'Passwords — those live in the platform keychain',
          ),
        ],
      ),
      const SettingsSection(
        label: 'Always on',
        children: [
          SettingsReadout(
            label: 'Transport',
            value: 'TLS only, certificates verified',
          ),
          SettingsReadout(
            label: 'Proxy fallback',
            value: 'None — a proxy that cannot be reached fails the connect',
          ),
          SettingsReadout(
            label: 'Message text',
            value: 'Control codes stripped in the native core before display',
          ),
          SettingsReadout(
            label: 'Rate limiting',
            value: 'Outgoing pacing and incoming flood protection, always on',
          ),
        ],
      ),
    ];
  }
}
