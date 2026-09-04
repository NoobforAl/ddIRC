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
      // The two paragraphs that used to sit under the readouts. Both are worth
      // saying and neither changes, which is exactly the kind of text that
      // becomes wallpaper if it is always on screen.
      help:
          'The port changes each time it starts, so the network in the rail '
          'is kept pointed at it for you. Your nickname and channels there '
          'are yours to change and are kept.\n\n'
          'Reachable only from this machine. Letting another machine in would '
          'mean handing it a certificate to install, and ddIRC will not build '
          'that.',
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
          // Not a note: the limit is a fact about the feature rather than
          // about this moment, so it lives behind the '?' on the heading with
          // the rest of what does not change. A failure still speaks up here,
          // because that is the opposite kind of thing.
          if (server.failure != null)
            SettingsNote(text: server.failure!, isError: true),
        ],
      ],
    );
  }
}
