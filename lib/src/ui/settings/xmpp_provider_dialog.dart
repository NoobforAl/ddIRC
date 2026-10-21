import 'package:flutter/material.dart';

import '../../model/xmpp_providers.dart';
import '../../theme.dart';
import '../link.dart';
import '../motion.dart';
import 'settings_chrome.dart';

/// Pick a server to make an XMPP account on.
///
/// An account is made on the server's own website, so this does two things and
/// no more: it opens that page - through [openLink], which shows where it goes
/// before anything leaves the app - and it hands back the server the user chose,
/// so the form can fill in where the account will live. It does not create an
/// account, ask for a password or connect.
class XmppProviderDialog extends StatelessWidget {
  const XmppProviderDialog({super.key});

  /// The server the user chose to use, or null if they closed it.
  static Future<XmppProvider?> show(BuildContext context) {
    return showSoftDialog<XmppProvider>(
      context: context,
      builder: (_) => const XmppProviderDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDialog(
      title: 'Choose a server',
      subtitle: 'Where to make an XMPP account',
      width: 460,
      children: [
        for (final provider in xmppProviders) _ProviderRow(provider: provider),
        const SettingsProse(
          'You make the account on the server’s own website, then come back '
          'and enter the address. ddIRC does not run these servers and cannot '
          'vouch for them: what was checked is that each answers over an '
          'encrypted connection with a valid certificate and that its sign-up '
          'page is open. Any other server works too — type its address by hand.',
          padding: EdgeInsets.fromLTRB(18, 12, 18, 14),
        ),
      ],
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.provider});

  final XmppProvider provider;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            provider.name,
            style: TextStyle(
              color: t.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            provider.blurb,
            style: TextStyle(color: t.muted, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              SettingsSecondaryButton(
                label: 'Open the sign-up page',
                onPressed: () => openLink(context, provider.signUpUrl),
              ),
              SettingsPrimaryButton(
                label: 'I have an account here',
                onPressed: () => Navigator.of(context).pop(provider),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
