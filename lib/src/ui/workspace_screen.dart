import 'package:flutter/material.dart';

import '../model/profile.dart';
import '../model/workspace.dart';
import '../theme.dart';
import 'app_mark.dart';
import 'layout.dart';
import 'motion.dart';
import 'network_rail.dart';
import 'session_screen.dart';
import 'settings/app_settings_dialog.dart';
import 'settings/network_picker_dialog.dart';
import 'settings/profile_editor_dialog.dart';
import 'touchable.dart';

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
        // The one measurement in the app. Taken here, inside the safe area and
        // below the window frame, so it is the room the app actually has —
        // everything below reads the answer rather than measuring again and
        // reaching a slightly different one.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final layout = Layout.forWidth(constraints.maxWidth);
            final rail = NetworkRail(
              workspace: workspace,
              onSelect: (profile) => _select(context, workspace, profile),
              onAdd: () => _edit(context, workspace, null),
              onBrowse: () => _browse(context, workspace),
              onEdit: (profile) => _edit(context, workspace, profile),
              onAppSettings: () => AppSettingsDialog.show(context),
            );

            return LayoutScope(
              layout: layout,
              child: Row(
                children: [
                  if (layout.channelsPinned) rail,
                  Expanded(
                    child: session == null
                        ? _Empty(
                            workspace: workspace,
                            layout: layout,
                            onAdd: () => _edit(context, workspace, null),
                            onBrowse: () => _browse(context, workspace),
                            onConnect: (p) => _select(context, workspace, p),
                            onAppSettings: () =>
                                AppSettingsDialog.show(context),
                          )
                        : SessionScreen(
                            // Rebuild the session subtree when the network
                            // changes, so scroll position and composer focus
                            // belong to one conversation rather than leaking
                            // across networks.
                            key: ValueKey(session.profileId),
                            session: session,
                            // Narrow: the rail has nowhere to stand, so it
                            // travels into the drawer with the channel list.
                            rail: layout.channelsPinned ? null : rail,
                          ),
                  ),
                ],
              ),
            );
          },
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

  /// Pick one of the networks ddIRC ships knowing about, then edit it.
  ///
  /// The picker hands over an address and a channel list; the editor is still
  /// what creates the profile, so the nickname is asked for and the proxy is
  /// reviewed exactly as they are for a network typed in by hand. Nothing is
  /// saved or dialled by browsing.
  static Future<void> _browse(BuildContext context, Workspace workspace) async {
    final pick = await NetworkPickerDialog.show(context);
    if (pick == null || !context.mounted) return;
    await _edit(context, workspace, null, preset: pick);
  }

  static Future<void> _edit(
    BuildContext context,
    Workspace workspace,
    Profile? profile, {
    NetworkPick? preset,
  }) async {
    final result = await ProfileEditorDialog.show(
      context,
      profile: profile,
      preset: preset,
    );
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
    required this.layout,
    required this.onAdd,
    required this.onBrowse,
    required this.onConnect,
    required this.onAppSettings,
  });

  final Workspace workspace;
  final Layout layout;
  final VoidCallback onAdd;
  final VoidCallback onBrowse;
  final ValueChanged<Profile> onConnect;
  final VoidCallback onAppSettings;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final profiles = workspace.profiles.profiles;

    return Center(
      // Scrollable rather than centred and clipped: a phone in landscape has
      // barely a couple of hundred points of height, and a saved network that
      // cannot be reached is worse than a list that scrolls.
      child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(
          horizontal: layout.gutter + 8,
          vertical: 24,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: AppMark(size: 44)),
              const SizedBox(height: 14),
              Text(
                'ddIRC',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, size: 12, color: t.muted),
                  const SizedBox(width: 5),
                  Text(
                    'Every connection uses TLS.',
                    style: TextStyle(fontSize: 12.5, color: t.muted),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              if (profiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'No networks yet. ddIRC already knows where the ones '
                    'still worth joining are.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: t.faint,
                      fontSize: 13,
                      height: 1.45,
                    ),
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
              // Browse leads, because on a fresh install it is the only one
              // of the two that can be answered by someone who does not
              // already know a server address by heart.
              TextButton.icon(
                onPressed: onBrowse,
                icon: const Icon(Icons.travel_explore, size: 17),
                label: const Text('Browse networks'),
                style: TextButton.styleFrom(
                  foregroundColor: t.accent,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  textStyle: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 16),
                label: Text(
                  profiles.isEmpty ? 'Add one by hand' : 'Add another by hand',
                ),
                style: TextButton.styleFrom(
                  foregroundColor: t.muted,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  textStyle: const TextStyle(fontSize: 12.5),
                ),
              ),
              // App settings live in the rail, and on a narrow screen the rail
              // is inside a drawer that only exists once something is
              // connected. Without this there is no route to settings at all
              // on a phone with no networks — which is the state every new
              // install starts in.
              if (!layout.channelsPinned)
                TextButton.icon(
                  onPressed: onAppSettings,
                  icon: const Icon(Icons.settings_outlined, size: 16),
                  label: const Text('App settings'),
                  style: TextButton.styleFrom(
                    foregroundColor: t.muted,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    textStyle: const TextStyle(fontSize: 12.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Try again, on a row that failed.
///
/// A button rather than "click the row again": after a failure the row is
/// carrying an error message, and clicking an error is not an obvious way to
/// ask for a second attempt. The icon turns as it is pressed, so the retry is
/// acknowledged before the connection has anything to report.
class _RetryButton extends StatefulWidget {
  const _RetryButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  State<_RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<_RetryButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  void _retry() {
    if (!context.motion.disabled) _turn.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Touchable(
      onTap: _retry,
      borderRadius: BorderRadius.circular(6),
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: t.surfaceHover.withValues(alpha: touch.wash),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: CurvedAnimation(parent: _turn, curve: Motion.curve),
              child: Icon(Icons.refresh, size: 14, color: t.accent),
            ),
            const SizedBox(width: 5),
            Text(
              'Retry',
              style: TextStyle(
                color: t.accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
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
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Touchable(
        // A network already dialling is not a second target; it stops
        // reporting hover so it stops looking like one.
        onTap: connecting ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        builder: (context, touch) => AnimatedContainer(
          duration: context.motion.fast,
          curve: Motion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: t.surfaceHover.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: failure != null ? t.bad.withValues(alpha: 0.4) : t.rule,
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
                      style: TextStyle(
                        color: t.text,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Nickname, unless the row has something more urgent to
                  // say. Switched rather than swapped, so a connection that
                  // fails does not blink between three unrelated states.
                  AnimatedSwitcher(
                    duration: context.motion.normal,
                    switchInCurve: Motion.curve,
                    switchOutCurve: Motion.exit,
                    transitionBuilder: Motion.scaleFade,
                    child: connecting
                        ? Row(
                            key: const ValueKey('connecting'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Spinner(color: t.warn, size: 12),
                              const SizedBox(width: 7),
                              Text(
                                'Connecting…',
                                style: TextStyle(color: t.muted, fontSize: 12),
                              ),
                            ],
                          )
                        : failure != null
                        ? _RetryButton(
                            key: const ValueKey('retry'),
                            onTap: onTap,
                          )
                        : Text(
                            profile.nickname,
                            key: const ValueKey('nick'),
                            style: TextStyle(color: t.muted, fontSize: 12),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${profile.host}:${profile.port}',
                style: TextStyle(color: t.faint, fontSize: 11.5),
              ),
              // The reason a network would not connect belongs with that
              // network, not in a banner that outlives the attempt.
              Reveal(
                child: failure == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          failure!,
                          style: TextStyle(
                            color: t.bad,
                            fontSize: 11.5,
                            height: 1.35,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
