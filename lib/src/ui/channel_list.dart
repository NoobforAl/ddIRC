import 'package:flutter/material.dart';

import '../model/session.dart';
import '../model/settings.dart';
import '../theme.dart';
import 'motion.dart';
import 'touchable.dart';

/// Joined channels and open conversations, with unread counts.
class ChannelList extends StatelessWidget {
  const ChannelList({
    super.key,
    required this.session,
    required this.networkName,
    required this.onSelect,
    this.onDisconnect,
    this.onChannelSettings,
  });

  final SessionModel session;

  /// What the user named this network, used until the server names itself.
  final String networkName;
  final ValueChanged<String> onSelect;
  final VoidCallback? onDisconnect;

  /// Opens the settings for one conversation — right-click or long-press.
  final ValueChanged<Conversation>? onChannelSettings;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final conversations = session.conversations;
    final active = session.active;
    // Read here rather than per row, so changing a channel's level in the
    // dialog repaints the whole list rather than one stale row.
    final settings = SettingsScope.of(context);

    return Container(
      color: t.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(t),
          Expanded(
            child: conversations.isEmpty
                ? Center(
                    child: Text(
                      'No channels yet.\nUse /join #channel',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: t.faint,
                        fontSize: 12,
                        height: 1.5,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: conversations.length,
                    itemBuilder: (context, i) {
                      final conversation = conversations[i];
                      return _ChannelRow(
                        conversation: conversation,
                        selected: identical(conversation, active),
                        onTap: () => onSelect(conversation.name),
                        onSettings: onChannelSettings == null
                            ? null
                            : () => onChannelSettings!(conversation),
                        muted:
                            settings.notifyFor(
                              session.profileId,
                              conversation.name,
                            ) ==
                            NotifyLevel.none,
                      );
                    },
                  ),
          ),
          if (onDisconnect != null) _footer(t),
        ],
      ),
    );
  }

  Widget _header(Tokens t) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  // The server's own name for the network wins once it
                  // arrives; until then, the name the user gave it.
                  session.network ?? networkName,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  session.nick,
                  style: TextStyle(color: t.muted, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer(Tokens t) {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: TextButton(
        onPressed: onDisconnect,
        style: TextButton.styleFrom(
          foregroundColor: t.muted,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: const RoundedRectangleBorder(),
        ),
        child: const Text('Disconnect', style: TextStyle(fontSize: 12.5)),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onSettings,
    required this.muted,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onSettings;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    final unread = conversation.unread;
    final mentions = conversation.unreadMentions;

    return Touchable(
      onTap: onTap,
      // Right-click on desktop, long-press on touch: the channel's own
      // settings, without a per-row button cluttering the list. The point the
      // gesture landed on is not wanted here — a dialog opens centred.
      onContextMenu: onSettings == null ? null : (_) => onSettings!(),
      builder: (context, touch) => AnimatedContainer(
        duration: m.normal,
        curve: Motion.curve,
        // The active channel is marked by a leading rule and a lifted
        // background — no pill, no fill, consistent with the hairline language.
        // Both slide across as selection moves, so the eye can follow it down
        // the list rather than re-finding it.
        decoration: BoxDecoration(
          // Hover and selection share a colour and differ only in weight, so
          // the pointer can preview a row without impersonating the one the
          // user is already in.
          color: selected
              ? t.surfaceHover
              : t.surfaceHover.withValues(alpha: touch.wash),
          border: Border(
            left: BorderSide(
              color: selected ? t.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          children: [
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: m.normal,
                curve: Motion.curve,
                // Merged onto the ambient style rather than replacing it, so
                // the row keeps whatever font the theme is handing down.
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: selected ? t.text : (unread > 0 ? t.text : t.muted),
                  fontSize: 13,
                  // Weight is what says "someone spoke here", so it is worth
                  // interpolating instead of snapping between two rows.
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(conversation.name, overflow: TextOverflow.ellipsis),
              ),
            ),
            // A request is not somewhere you are, so it is not dressed as one.
            // An unanswered question with a badge on it would read as a
            // conversation with unread messages, which is precisely the
            // impression this is meant to withhold until the user decides.
            Appear(
              child: conversation.pending
                  ? Padding(
                      key: const ValueKey('pending'),
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.person_add_alt_1_outlined,
                        size: 13,
                        color: t.accent,
                      ),
                    )
                  : null,
            ),
            // The gaps live inside the switchers, so a row carrying neither
            // ornament closes up rather than holding an empty slot open.
            Appear(
              child: muted
                  ? Padding(
                      key: const ValueKey('muted'),
                      padding: const EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.notifications_off_outlined,
                        size: 13,
                        color: t.faint,
                      ),
                    )
                  : null,
            ),
            Appear(
              child: unread > 0 && !conversation.pending
                  ? Padding(
                      // Keyed on presence, not on the count: an active channel
                      // would otherwise re-scale the badge on every message.
                      key: const ValueKey('badge'),
                      padding: const EdgeInsets.only(left: 8),
                      child: _Badge(count: unread, highlighted: mentions > 0),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.highlighted});

  final int count;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        // A mention is worth interrupting for; ambient chatter is not.
        color: highlighted ? t.accent : t.badge,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: highlighted ? t.onAccent : t.text,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
