import 'package:flutter/material.dart';

import '../../model/local_server.dart';
import 'settings_chrome.dart';

/// The IRC server inside the app, as shown in App settings — beta.
///
/// One switch, and a network appears. That is the whole feature: somewhere to
/// talk that needs nothing installed, no account made and no network's
/// permission — a scratch network for trying things, or a target that is there
/// when nothing else is.
class LocalServerSection extends StatefulWidget {
  const LocalServerSection({super.key});

  @override
  State<LocalServerSection> createState() => _LocalServerSectionState();
}

class _LocalServerSectionState extends State<LocalServerSection> {
  bool _busy = false;

  Future<void> _set(LocalServerSettings server, bool on) async {
    setState(() => _busy = true);
    await server.setEnabled(on);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final server = LocalServerScope.of(context);

    return SettingsSection(
      label: 'Local server',
      beta: true,
      children: [
        SettingsSwitch(
          label: 'Run an IRC server in this app',
          description:
              'A small server on this machine, and a network in the rail '
              'pointing at it. Nothing to install and no account to make. '
              'Only this machine can reach it.',
          value: server.enabled,
          onChanged: _busy ? (_) {} : (v) => _set(server, v),
        ),
        if (server.enabled) ...[
          SettingsReadout(
            label: 'Status',
            value: server.running ? 'Running' : 'Not running',
          ),
          SettingsReadout(
            label: 'Address',
            value: server.port == null
                ? 'None yet'
                : '127.0.0.1:${server.port}',
          ),
          SettingsReadout(
            label: 'Network',
            value: server.networkName ?? 'None yet',
          ),
          // Said rather than left to be discovered. The port is different at
          // every start, so the network in the rail is maintained by this
          // switch and not something to configure by hand.
          const SettingsNote(
            text:
                'The port changes each time it starts, so the network in the '
                'rail is kept pointed at it for you. Your nickname and '
                'channels there are yours to change and are kept.',
          ),
          // The one thing about it that is genuinely a limit rather than a
          // default, and the reason is worth giving in full.
          const SettingsNote(
            text:
                'Reachable only from this machine. Letting another machine in '
                'would mean handing it a certificate to install, and ddIRC '
                'will not build that.',
          ),
          if (server.failure != null)
            SettingsNote(text: server.failure!, isError: true),
        ],
      ],
    );
  }
}
