import 'package:flutter/material.dart';

import '../model/profile.dart';
import '../model/workspace.dart';
import '../theme.dart';
import 'network_rail.dart';
import 'session_screen.dart';
import 'settings/profile_editor_dialog.dart';

/// The whole app: networks on the left, then the selected network's session.
///
/// One screen rather than a connect screen that pushes a session screen. With
/// several connections live at once there is no "the" session to push, and
/// popping back would have meant tearing one down.
class WorkspaceScreen extends StatelessWidget {
  const WorkspaceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final workspace = WorkspaceScope.of(context);
    // Depend on the store as well, so adding or renaming a profile repaints
    // the rail even while no connection state has changed.
    ProfileScope.of(context);

    final session = workspace.active;

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            NetworkRail(
              workspace: workspace,
              onSelect: (profile) => _select(context, workspace, profile),
              onAdd: () => _edit(context, workspace, null),
              onEdit: (profile) => _edit(context, workspace, profile),
            ),
            Expanded(
              child: session == null
                  ? _Empty(
                      workspace: workspace,
                      onAdd: () => _edit(context, workspace, null),
                      onConnect: (p) => _select(context, workspace, p),
                    )
                  : SessionScreen(
                      // Rebuild the session subtree when the network changes,
                      // so scroll position and composer focus belong to one
                      // conversation rather than leaking across networks.
                      key: ValueKey(session.profileId),
                      session: session,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Tapping a network selects it, or connects it if it is not up yet.
  static Future<void> _select(
    BuildContext context,
    Workspace workspace,
    Profile profile,
  ) async {
    if (workspace.isConnected(profile.id)) {
      workspace.select(profile.id);
      return;
    }
    await workspace.connect(profile);
  }

  static Future<void> _edit(
    BuildContext context,
    Workspace workspace,
    Profile? profile,
  ) async {
    final result = await ProfileEditorDialog.show(context, profile: profile);
    if (result != ProfileEditorResult.savedAndConnect) return;

    // The editor saved a profile; find it again by id rather than holding the
    // instance, since saving replaced it.
    final id = profile?.id;
    final saved = id == null
        ? workspace.profiles.profiles.last
        : workspace.profiles.byId(id);
    if (saved == null) return;

    if (workspace.isConnected(saved.id)) {
      workspace.select(saved.id);
    } else {
      await workspace.connect(saved);
    }
  }
}

/// Shown when nothing is connected.
class _Empty extends StatelessWidget {
  const _Empty({
    required this.workspace,
    required this.onAdd,
    required this.onConnect,
  });

  final Workspace workspace;
  final VoidCallback onAdd;
  final ValueChanged<Profile> onConnect;

  @override
  Widget build(BuildContext context) {
    final profiles = workspace.profiles.profiles;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'ddIRC',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w600,
                color: Tokens.text,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.lock_outline, size: 12, color: Tokens.muted),
                SizedBox(width: 5),
                Text(
                  'Every connection uses TLS.',
                  style: TextStyle(fontSize: 12.5, color: Tokens.muted),
                ),
              ],
            ),
            const SizedBox(height: 26),
            if (profiles.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'No networks yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Tokens.faint, fontSize: 13),
                ),
              )
            else ...[
              for (final profile in profiles)
                _ProfileRow(
                  profile: profile,
                  connecting: workspace.isConnecting(profile.id),
                  failure: workspace.failureFor(profile.id),
                  onTap: () => onConnect(profile),
                ),
              const SizedBox(height: 14),
            ],
            TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add, size: 17),
              label: Text(profiles.isEmpty ? 'Add a network' : 'Add another'),
              style: TextButton.styleFrom(
                foregroundColor: Tokens.accent,
                padding: const EdgeInsets.symmetric(vertical: 13),
                textStyle: const TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.profile,
    required this.connecting,
    required this.failure,
    required this.onTap,
  });

  final Profile profile;
  final bool connecting;
  final String? failure;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: connecting ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: failure != null
                  ? Tokens.bad.withValues(alpha: 0.4)
                  : Tokens.rule,
              width: Tokens.hairline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      profile.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Tokens.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    connecting ? 'Connecting…' : profile.nickname,
                    style: const TextStyle(color: Tokens.muted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${profile.host}:${profile.port}',
                style: const TextStyle(color: Tokens.faint, fontSize: 11.5),
              ),
              // The reason a network would not connect belongs with that
              // network, not in a banner that outlives the attempt.
              if (failure != null) ...[
                const SizedBox(height: 6),
                Text(
                  failure!,
                  style: const TextStyle(
                    color: Tokens.bad,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
