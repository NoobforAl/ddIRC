import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme.dart';
import 'settings/settings_chrome.dart';

/// Open a link someone sent — after showing where it actually goes.
///
/// A link in a chat line is a stranger's text, and the text and the address
/// are the same thing here only because nothing renders a label over it. Even
/// so, the whole address is shown before anything opens: a long one is cut
/// off in a bubble, and what is past the cut is exactly where a lookalike
/// domain hides. Opening a browser is leaving the app, and it should be a
/// step the user takes on purpose.
///
/// Only `http` and `https`. Anything else — `file:`, `javascript:`, an app's
/// private scheme — is refused rather than handed to the platform.
Future<void> openLink(BuildContext context, String address) async {
  final uri = Uri.tryParse(address);
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;

  final go = await showDialog<bool>(
    context: context,
    builder: (context) => _OpenLinkDialog(uri: uri),
  );
  if (go != true) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('Could not open the link ($error)')),
    );
  }
}

class _OpenLinkDialog extends StatelessWidget {
  const _OpenLinkDialog({required this.uri});

  final Uri uri;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SettingsDialog(
      title: 'Open this link?',
      subtitle: uri.host,
      width: 420,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
          child: SelectableText(
            uri.toString(),
            style: TextStyle(
              color: t.text,
              fontSize: 13,
              fontFamily: Fonts.mono,
              fontFamilyFallback: Fonts.monoFallback,
            ),
          ),
        ),
        const SettingsNote(
          text:
              'It opens in your browser. Whoever runs the site sees your '
              'address, unless your browser goes through a proxy of its own — '
              'ddIRC\'s proxy does not carry it.',
        ),
        SettingsActions(
          children: [
            SettingsSecondaryButton(
              label: 'Cancel',
              onPressed: () => Navigator.of(context).pop(false),
            ),
            SettingsPrimaryButton(
              label: 'Open',
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ],
        ),
      ],
    );
  }
}
