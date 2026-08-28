import 'package:flutter/material.dart';

import '../../model/proxy.dart';
import '../../model/settings.dart';
import '../../theme.dart';
import 'settings_chrome.dart';

/// Receiving files over DCC, as shown in App settings — beta.
///
/// The only switch in this dialog that asks before it will turn on, and the
/// reason is that it is the only one whose cost is not paid by the person
/// flipping it. Every other setting here decides how the app looks or what it
/// writes to its own disk. This one decides whether a stranger's message can
/// end in a TCP connection between their machine and this one — and, if you
/// ever send a file, whether your address is handed to whoever asked for it.
///
/// So the dialog is not a confirmation. It is the explanation, and the switch
/// is the answer to it.
class FileTransferSection extends StatefulWidget {
  const FileTransferSection({super.key});

  @override
  State<FileTransferSection> createState() => _FileTransferSectionState();
}

class _FileTransferSectionState extends State<FileTransferSection> {
  Future<void> _set(AppSettings settings, bool on) async {
    // Turning it off needs no ceremony: nobody has to be talked into being
    // safer, and a confirmation on the way out is just an obstacle.
    if (!on) {
      settings.fileTransfers = false;
      return;
    }
    final accepted = await _RiskDialog.show(context);
    if (accepted && mounted) {
      settings.fileTransfers = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);
    final proxies = ProxyScope.of(context);
    final on = settings.fileTransfers;

    return SettingsSection(
      label: 'File transfers',
      beta: true,
      children: [
        SettingsSwitch(
          label: 'File transfers',
          description:
              'IRC sends files over a direct connection between the two '
              'clients, not through the server. Off, offers are not shown at '
              'all and there is no way to send one. On, you can accept what '
              'is offered to you and attach a file of your own.',
          value: on,
          onChanged: (v) => _set(settings, v),
        ),
        if (on) ...[
          // Said plainly rather than left to be discovered by looking for a
          // button that is not there. What this switch decides today is
          // whether an offer is *displayed*; the rest of what it will mean is
          // in the dialog that turned it on.
          const SettingsReadout(
            label: 'Received files',
            value: 'Saved inside ddIRC, not in your Downloads folder',
          ),
          const SettingsReadout(
            label: 'Sending',
            value: 'The offer carries your address — you are asked each time',
          ),
          SettingsReadout(
            label: 'Filenames',
            value: 'Reduced to a bare name — an offer cannot choose a path',
          ),
          // The interaction that would otherwise be found the hard way, by
          // someone who thought Tor covered everything they do.
          if (proxies.overridesProfiles)
            const SettingsNote(
              text:
                  'Built-in Tor is on, and file transfers follow it. Accepting '
                  'an offer dials the sender through the proxy, so it is your '
                  'exit that reaches them and not you. Sending is refused '
                  'while a proxy is on, because an offer has to name an '
                  'address and there is no honest one to give.',
            ),
        ],
      ],
    );
  }
}

/// What is actually being agreed to.
///
/// Written as facts rather than warnings. "Are you sure?" tells nobody
/// anything; a person who knows their address is exposed can decide for
/// themselves whether that matters on their network.
class _RiskDialog extends StatelessWidget {
  const _RiskDialog();

  static Future<bool> show(BuildContext context) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (_) => const _RiskDialog(),
    );
    return answer ?? false;
  }

  static const _risks = [
    (
      'Sending gives away where you are',
      'An offer has to name an address for the other client to dial, and on '
          'a channel everyone present sees it. You are asked before every '
          'send, and told who will learn it.',
    ),
    (
      'You connect to an address a stranger chose',
      'Accepting means dialling the host and port in their message. Nothing '
          'is dialled until you press Accept, and declining sends nothing at '
          'all — so an offer you ignore tells them nothing.',
    ),
    (
      'The file is not checked',
      'Nothing here scans it, and the name and size in an offer are claims, '
          'not facts. A file that says it is a 4 KB image may be neither.',
    ),
    (
      'With no proxy, it is a direct connection',
      'Whoever is at the other end learns your address, and so does anyone '
          'who can see their traffic. With a proxy or Tor configured a '
          'transfer follows it instead, and sending is refused rather than '
          'quietly going around it.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;

    return SettingsDialog(
      title: 'Before you turn this on',
      subtitle: 'File transfers — beta',
      width: 460,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
          child: Text(
            'IRC has no way to send a file through the server. Every client '
            'that can send one does it by opening a connection directly to '
            'the other machine, which has consequences worth knowing before '
            'rather than after.',
            style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.45),
          ),
        ),
        for (final (heading, body) in _risks)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading,
                  style: TextStyle(
                    color: t.warn,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(color: t.muted, fontSize: 12, height: 1.45),
                ),
              ],
            ),
          ),
        const SizedBox(height: 6),
        const SettingsNote(
          text:
              'Today this only decides whether an offer is shown. There is no '
              'way to accept one yet, and nothing is ever accepted for you. '
              'The facts above are what accepting will mean when it is built.',
        ),
        SettingsActions(
          children: [
            // The safer answer takes the emphasis, and the other one is
            // still one click away. A consent dialog that urges the choice it
            // is warning about has not really asked anything.
            SettingsSecondaryButton(
              label: 'Turn it on',
              onPressed: () => Navigator.of(context).pop(true),
            ),
            SettingsPrimaryButton(
              label: 'Leave it off',
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
