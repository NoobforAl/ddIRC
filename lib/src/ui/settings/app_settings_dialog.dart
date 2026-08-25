import 'package:flutter/material.dart';

import '../../model/log.dart';
import '../../model/settings.dart';
import 'proxy_section.dart';
import 'settings_chrome.dart';

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
        SettingsSection(
          label: 'Appearance',
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
        const SettingsRule(),
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
        const SettingsRule(),
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
                  'already corrected; turn this off to ignore them entirely.',
              value: settings.renderColors,
              onChanged: (v) => settings.renderColors = v,
            ),
          ],
        ),
        const SettingsRule(),
        SettingsSection(
          label: 'Logging',
          children: [
            SettingsSwitch(
              label: 'Save chat logs',
              description:
                  'Writes what is said to a file, in plain text. This is '
                  'the most sensitive thing the app can store — anyone who '
                  'can read the folder can read your conversations.',
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
              // Shown whether or not either switch is on, so it is possible
              // to know where the files would go before agreeing to them.
              value:
                  AppLog.instance.directoryPath ??
                  'Unavailable on this platform',
            ),
          ],
        ),
        const SettingsRule(),
        const GlobalProxySection(),
        const SettingsRule(),
        const SettingsSection(
          label: 'Security',
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
        const SizedBox(height: 10),
      ],
    );
  }
}
