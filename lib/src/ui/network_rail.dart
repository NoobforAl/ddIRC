import 'package:flutter/material.dart';

import '../model/profile.dart';
import '../model/workspace.dart';
import '../rust/api/types.dart';
import '../theme.dart';
import 'motion.dart';
import 'touchable.dart';

/// Width of the rail. Just wide enough for a 34px mark and its gutters.
const double networkRailWidth = 56;

/// One column, one network.
///
/// Every saved profile is here whether or not it is connected: the rail is the
/// list of places the user goes, not a list of open sockets. Connected ones
/// carry a status dot and unread count; the rest sit dimmed until clicked.
class NetworkRail extends StatelessWidget {
  const NetworkRail({
    super.key,
    required this.workspace,
    required this.onSelect,
    required this.onAdd,
    required this.onEdit,
    required this.onAppSettings,
  });

  final Workspace workspace;
  final ValueChanged<Profile> onSelect;
  final VoidCallback onAdd;
  final ValueChanged<Profile> onEdit;
  final VoidCallback onAppSettings;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final profiles = workspace.profiles.profiles;

    return Container(
      width: networkRailWidth,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          right: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: profiles.length,
              itemBuilder: (context, i) {
                final profile = profiles[i];
                return _RailEntry(
                  profile: profile,
                  session: workspace.sessionFor(profile.id),
                  connecting: workspace.isConnecting(profile.id),
                  failed: workspace.failureFor(profile.id) != null,
                  selected: workspace.activeProfileId == profile.id,
                  unread: workspace.unreadFor(profile.id),
                  mentions: workspace.mentionsFor(profile.id),
                  onTap: () => onSelect(profile),
                  onEdit: () => onEdit(profile),
                );
              },
            ),
          ),
          const Divider(height: Tokens.hairline),
          _RailButton(icon: Icons.add, tooltip: 'Add a network', onTap: onAdd),
          // The rail is the only surface on screen in every state, so it is
          // also the only place app settings can always be reached from.
          _RailButton(
            icon: Icons.settings_outlined,
            tooltip: 'App settings',
            onTap: onAppSettings,
          ),
        ],
      ),
    );
  }
}

class _RailEntry extends StatelessWidget {
  const _RailEntry({
    required this.profile,
    required this.session,
    required this.connecting,
    required this.failed,
    required this.selected,
    required this.unread,
    required this.mentions,
    required this.onTap,
    required this.onEdit,
  });

  final Profile profile;
  final Object? session;
  final bool connecting;
  final bool failed;
  final bool selected;
  final int unread;
  final int mentions;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  bool get connected => session != null;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Touchable(
        onTap: onTap,
        onSecondaryTap: onEdit,
        onLongPress: onEdit,
        builder: (context, touch) => SizedBox(
          height: 42,
          child: Row(
            children: [
              // The same 2px leading rule the channel list uses for its
              // selection, so "where am I" reads identically in both columns.
              AnimatedContainer(
                duration: m.normal,
                curve: Motion.curve,
                width: 2,
                height: 26,
                color: selected ? t.accent : Colors.transparent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _Mark(
                  profile: profile,
                  connected: connected,
                  selected: selected,
                  connecting: connecting,
                  failed: failed,
                  unread: unread,
                  mentions: mentions,
                  touch: touch,
                ),
              ),
              const SizedBox(width: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _Mark extends StatelessWidget {
  const _Mark({
    required this.profile,
    required this.connected,
    required this.selected,
    required this.connecting,
    required this.failed,
    required this.unread,
    required this.mentions,
    required this.touch,
  });

  final Profile profile;
  final bool connected;
  final bool selected;
  final bool connecting;
  final bool failed;
  final int unread;
  final int mentions;
  final Touch touch;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    final live = connected || connecting;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        AnimatedContainer(
          duration: m.normal,
          curve: Motion.curve,
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            // Selection and hover share a colour and differ only in weight,
            // so the pointer can preview a row without impersonating the one
            // the user is already in. Transparent rather than null, so the
            // fill fades up from nothing instead of being stamped on.
            color: selected
                ? t.surfaceHover
                : t.surfaceHover.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: selected ? t.accent : t.rule,
              width: selected ? 1 : Tokens.hairline,
            ),
          ),
          child: AnimatedDefaultTextStyle(
            duration: m.normal,
            curve: Motion.curve,
            // Merged onto the ambient style rather than replacing it, so the
            // mark keeps whatever font the theme is handing down.
            style: DefaultTextStyle.of(context).style.copyWith(
              // A disconnected network is legible but clearly dormant; coming
              // up is the fade between the two.
              color: live ? t.text : t.faint,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
            child: Text(profile.initials),
          ),
        ),
        // Two fixed corners rather than one switcher between them: the count
        // sits above the mark and the pip below it, so they have nowhere to
        // cross-fade to. Each arrives and leaves on its own.
        Positioned(
          top: -3,
          right: -5,
          child: Appear(
            child: unread > 0
                // Keyed on presence, not on the number: an active channel
                // would otherwise re-scale the badge on every message.
                ? _Count(
                    key: const ValueKey('count'),
                    count: unread,
                    highlighted: mentions > 0,
                  )
                : null,
          ),
        ),
        Positioned(
          bottom: -1,
          right: -1,
          child: Appear(
            child: unread == 0 && (live || failed)
                ? _StatusPip(
                    key: const ValueKey('pip'),
                    connecting: connecting,
                    failed: failed && !connected,
                  )
                : null,
          ),
        ),
      ],
    );
  }
}

/// A dot in the corner of the mark: connected, trying, or failed.
class _StatusPip extends StatelessWidget {
  const _StatusPip({super.key, required this.connecting, required this.failed});

  final bool connecting;
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = failed
        ? t.bad
        : connecting
        ? t.warn
        : t.ok;

    return Pulse(
      running: connecting,
      child: AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          // Ringed in the panel colour so it reads as sitting on top of the
          // mark rather than being part of its border.
          border: Border.all(color: t.surface, width: 1.5),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({super.key, required this.count, required this.highlighted});

  final int count;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: highlighted ? t.accent : t.badge,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.surface, width: 1.5),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: highlighted ? t.onAccent : t.text,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// One of the utility buttons in the rail's footer.
///
/// The rail is too narrow for a label, so the tooltip is the only thing that
/// names the action.
class _RailButton extends StatelessWidget {
  const _RailButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    return Tooltip(
      message: tooltip,
      child: Touchable(
        onTap: onTap,
        builder: (context, touch) => AnimatedContainer(
          duration: m.fast,
          curve: Motion.curve,
          height: 46,
          alignment: Alignment.center,
          color: t.surfaceHover.withValues(alpha: touch.wash),
          // The icon comes forward as well. A wash alone is easy to miss on a
          // strip this narrow, and the icon is the part being aimed at.
          child: TweenAnimationBuilder<Color?>(
            duration: m.fast,
            curve: Motion.curve,
            tween: ColorTween(end: touch == Touch.none ? t.muted : t.text),
            builder: (context, color, _) => Icon(icon, size: 19, color: color),
          ),
        ),
      ),
    );
  }
}

/// The connection status of one session, for the rail and the header.
Color statusColor(ConnectionStatus status, Tokens t) => switch (status) {
  ConnectionStatus_Connected() => t.ok,
  ConnectionStatus_Connecting() => t.warn,
  ConnectionStatus_Registering() => t.warn,
  ConnectionStatus_Reconnecting() => t.warn,
  ConnectionStatus_Disconnected() => t.bad,
};
