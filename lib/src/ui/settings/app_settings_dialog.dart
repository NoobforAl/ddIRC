import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../model/local_server.dart';
import '../../model/log.dart';
import '../../model/proxy.dart';
import '../../model/settings.dart';
import '../background.dart';
import '../motion.dart';
import '../notifier.dart' show notificationsSupportedOn;
import 'file_transfer_section.dart';
import 'local_server_section.dart';
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

/// The three pages of app settings.
///
/// Naming them in an enum rather than building three lists inline is what
/// makes the index and the page the same decision: a page cannot be reachable
/// from the index and then turn out not to exist, and a new one cannot be
/// added without a summary line, because the enum requires it.
enum _Page {
  appearance('Appearance', 'How the app looks and how much it says'),
  connection('Connection', 'How and where ddIRC connects'),
  privacy('Privacy', 'What is written down, and what is always on');

  const _Page(this.label, this.subtitle);

  final String label;

  /// Shown under the page's own title once it is open. Says what the page is
  /// for, where the index row says what is currently set in it.
  final String subtitle;
}

/// Preferences that apply everywhere, on every server.
///
/// An index and three pages, rather than nine sections in one column. The
/// dialog reached the length where scrolling was how you found anything, and
/// everything looking equally important is the same as nothing being
/// findable — someone looking for the proxy had to read past the timestamps to
/// be sure they had not gone by it.
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
          // Sized as well as switched. The three pages are very different
          // heights, and a dialog that jumped from the index straight to the
          // full height of Connection would move the back arrow out from
          // under the pointer that just arrived on it.
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
      const SettingsRule(),
      SettingsNavRow(
        label: _Page.privacy.label,
        summary: _privacySummary(settings),
        onTap: () => _open(_Page.privacy),
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

  static String _privacySummary(AppSettings settings) {
    final on = [
      if (settings.saveChatLogs) 'chat logs',
      if (settings.saveDebugLogs) 'debug logs',
    ];
    return on.isEmpty
        ? 'Nothing written to disk'
        : 'Saving ${on.join(' and ')}';
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
    final settings = SettingsScope.of(context);
    return [
      // Staying connected belongs here rather than under Appearance, whatever
      // the heading says on this platform: what the switch decides is whether
      // the sockets outlive the window.
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
      // Beside staying connected, because it is the other half of the same
      // promise: one keeps the socket open while you are elsewhere, and this is
      // how you find out that it caught something.
      if (notificationsSupportedOn(defaultTargetPlatform))
        SettingsSection(
          label: 'Notifications',
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
      // Ordered by how far the connection travels: a server on this machine,
      // then Tor, then somewhere the user runs themselves.
      const LocalServerSection(),
      const TorSection(),
      const GlobalProxySection(),
      // Last, because it is the one that does not go through any of the three
      // above — which is the thing about it worth noticing.
      const FileTransferSection(),
    ];
  }

  List<Widget> _privacy(BuildContext context) {
    final settings = SettingsScope.of(context);
    return [
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
