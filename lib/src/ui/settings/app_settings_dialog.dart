import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../model/log.dart';
import '../../model/settings.dart';
import '../background.dart';
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

/// Preferences that apply everywhere, on every server.
///
/// Each change takes effect immediately and writes through to disk. The one
/// exception is the proxy, which is a typed address rather than a switch and
/// so has a state that is neither the old value nor a working new one; it
/// carries its own buttons and explains why.
class AppSettingsDialog extends StatelessWidget {
  const AppSettingsDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const AppSettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);

    return SettingsDialog(
      title: 'App settings',
      subtitle: 'Applies to every server',
      children: [
        // Three categories rather than nine sections in a row. The dialog got
        // long enough that everything read as equally important, which is the
        // same as nothing being findable: someone looking for the proxy had to
        // read past the timestamps to be sure they had not missed it.
        SettingsCategory(
          first: true,
          label: 'Appearance',
          children: [
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
          ],
        ),
        SettingsCategory(
          label: 'Connection',
          children: [
            // Staying connected belongs here rather than under Appearance,
            // whatever the heading says on this platform: what the switch
            // decides is whether the sockets outlive the window.
            //
            // Absent on iOS rather than shown and disabled: the OS will not
            // hold a socket open for an app that is not in front, so the
            // switch would be a promise the platform refuses to keep, and a
            // control that cannot keep its promise is worse than no control.
            if (keepsRunningInBackground)
              SettingsSection(
                label: _backgroundSectionLabel,
                children: [
                  SettingsSwitch(
                    label: _backgroundSwitchLabel,
                    description: backgroundSettingDescription(
                      defaultTargetPlatform,
                    ),
                    value: settings.runInBackground,
                    onChanged: (v) => settings.runInBackground = v,
                  ),
                ],
              ),
            // Ordered by how far the connection travels: a server on this
            // machine, then Tor, then somewhere the user runs themselves.
            const LocalServerSection(),
            const TorSection(),
            const GlobalProxySection(),
          ],
        ),
        SettingsCategory(
          label: 'Privacy',
          children: [
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
                  // Shown whether or not either switch is on, so it is
                  // possible to know where the files would go before agreeing
                  // to them.
                  value:
                      AppLog.instance.directoryPath ??
                      'Unavailable on this platform',
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
                  value:
                      'None — a proxy that cannot be reached fails the '
                      'connect',
                ),
                SettingsReadout(
                  label: 'Message text',
                  value:
                      'Control codes stripped in the native core before '
                      'display',
                ),
                SettingsReadout(
                  label: 'Rate limiting',
                  value:
                      'Outgoing pacing and incoming flood protection, always '
                      'on',
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
      ],
    );
  }
}
