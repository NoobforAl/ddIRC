import 'package:flutter/material.dart';

import '../model/profile.dart';
import '../model/settings.dart';
import '../model/workspace.dart';
import '../theme.dart';
import 'menu.dart';
import 'settings/settings_chrome.dart';

/// What the context menu on a network offers.
enum NetworkMenuAction { edit, delete }

/// The menu a network opens on right-click, or on a long press.
///
/// Both surfaces that list networks — the rail and the list on the empty
/// screen — put the same two things here, because the two questions asked of a
/// saved network that is not "connect me" are "change this" and "I am done
/// with this". Neither had a route from the list before: editing was hidden
/// behind an undiscoverable right-click that opened the whole editor, and
/// deleting was only reachable by opening the editor first and finding the
/// button at the bottom.
Future<NetworkMenuAction?> showNetworkMenu(
  BuildContext context,
  Profile profile,
  Offset at,
) {
  return showPointerMenu<NetworkMenuAction>(
    context,
    at: at,
    items: [
      PopupMenuItem(
        value: NetworkMenuAction.edit,
        child: const MenuRow(icon: Icons.edit_outlined, label: 'Edit network…'),
      ),
      PopupMenuItem(
        value: NetworkMenuAction.delete,
        child: MenuRow(
          icon: Icons.delete_outline,
          label: 'Delete ${profile.name}…',
          danger: true,
        ),
      ),
    ],
  );
}

/// Delete a network everywhere it is remembered, connection included.
///
/// One function rather than one per caller, because the order matters and
/// getting it wrong is silent: drop the live connection before the profile it
/// belongs to, so nothing is left holding a socket for a network that no
/// longer exists.
///
/// Everything is read out of the tree before the first await. A profile being
/// deleted may be the one whose row invoked this, and that row is about to
/// stop existing.
Future<void> forgetNetwork(BuildContext context, Profile profile) async {
  final store = ProfileScope.of(context);
  final workspace = WorkspaceScope.of(context);
  final settings = SettingsScope.of(context);

  workspace.forget(profile.id);
  await settings.forgetProfile(profile.id);
  await store.remove(profile.id);
}

/// What deleting a network takes with it.
///
/// The editor's Delete button sits at the bottom of a form the user opened on
/// purpose and read on the way down. A menu item is one click from a row, so
/// this says out loud what goes — including the parts kept somewhere other
/// than app settings, which are the ones nobody expects to lose.
class ForgetNetworkDialog extends StatelessWidget {
  const ForgetNetworkDialog({super.key, required this.profile});

  final Profile profile;

  /// Returns true if the user went through with it.
  static Future<bool> show(BuildContext context, Profile profile) async {
    final answer = await showDialog<bool>(
      context: context,
      builder: (_) => ForgetNetworkDialog(profile: profile),
    );
    return answer ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final connected = WorkspaceScope.of(context).isConnected(profile.id);

    final goes = [
      ('The saved server', '${profile.host}:${profile.port}, and its channels'),
      if (profile.usesSasl)
        (
          'Its account password',
          'Removed from the platform keychain, not just from this list.',
        ),
      if (profile.usesProxyAuth)
        ('Its proxy password', 'Also kept in the keychain, and also removed.'),
      (
        'Who you blocked here',
        'Block lists are per network. Deleting this one forgets who was '
            'turned away on it, along with the per-channel notification '
            'levels.',
      ),
      if (connected)
        (
          'The connection you are on',
          'ddIRC is on this network right now. It says goodbye to the server '
              'and closes the conversations.',
        ),
    ];

    return SettingsDialog(
      title: 'Delete ${profile.name}?',
      subtitle: connected ? 'Connected right now' : 'Saved network',
      width: 420,
      children: [
        for (final (heading, body) in goes)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading,
                  style: TextStyle(
                    color: t.text,
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
        const SizedBox(height: 10),
        const SettingsNote(
          text:
              'Nothing here is recoverable — ddIRC keeps no copy of a deleted '
              'network. The chat log on disk, if you have one turned on, is '
              'not touched.',
        ),
        SettingsActions(
          children: [
            // Keeping is the primary, deleting the outlined one beside it.
            // A dialog that puts its weight behind the irreversible answer
            // has not really asked.
            SettingsDangerButton(
              label: connected ? 'Delete & disconnect' : 'Delete',
              onPressed: () => Navigator.of(context).pop(true),
            ),
            SettingsPrimaryButton(
              label: 'Keep it',
              onPressed: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}
