import 'package:flutter/material.dart';

import '../model/session.dart';
import '../model/settings.dart';
import '../theme.dart';

/// Joined channels and open conversations, with unread counts.
class ChannelList extends StatelessWidget {
  const ChannelList({
    super.key,
    required this.session,
    required this.networkName,
    required this.onSelect,
    this.onDisconnect,
    this.onChannelSettings,
    this.onAppSettings,
  });

  final SessionModel session;

  /// What the user named this network, used until the server names itself.
  final String networkName;
  final ValueChanged<String> onSelect;
  final VoidCallback? onDisconnect;

  /// Opens the settings for one conversation — right-click or long-press.
  final ValueChanged<Conversation>? onChannelSettings;
  final VoidCallback? onAppSettings;

  @override
  Widget build(BuildContext context) {
    final conversations = session.conversations;
    final active = session.active;
    // Read here rather than per row, so changing a channel's level in the
    // dialog repaints the whole list rather than one stale row.
    final settings = SettingsScope.of(context);

    return Container(
      color: Tokens.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(),
          Expanded(
            child: conversations.isEmpty
                ? const Center(
                    child: Text(
                      'No channels yet.\nUse /join #channel',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Tokens.faint,
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
          if (onDisconnect != null) _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Tokens.rule, width: Tokens.hairline),
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
                  style: const TextStyle(
                    color: Tokens.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  session.nick,
                  style: const TextStyle(color: Tokens.muted, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onAppSettings != null)
            IconButton(
              onPressed: onAppSettings,
              icon: const Icon(Icons.settings_outlined, size: 17),
              color: Tokens.muted,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              tooltip: 'App settings',
            ),
        ],
      ),
    );
  }

  Widget _footer() {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Tokens.rule, width: Tokens.hairline),
        ),
      ),
      child: TextButton(
        onPressed: onDisconnect,
        style: TextButton.styleFrom(
          foregroundColor: Tokens.muted,
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
    final unread = conversation.unread;
    final mentions = conversation.unreadMentions;

    return InkWell(
      onTap: onTap,
      // Right-click on desktop, long-press on touch: the channel's own
      // settings, without a per-row button cluttering the list.
      onSecondaryTap: onSettings,
      onLongPress: onSettings,
      child: Container(
        // The active channel is marked by a leading rule and a lifted
        // background — no pill, no fill, consistent with the hairline language.
        decoration: BoxDecoration(
          color: selected ? Tokens.surfaceHover : null,
          border: Border(
            left: BorderSide(
              color: selected ? Tokens.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                conversation.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected
                      ? Tokens.text
                      : (unread > 0 ? Tokens.text : Tokens.muted),
                  fontSize: 13,
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (muted) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.notifications_off_outlined,
                size: 13,
                color: Tokens.faint,
              ),
            ],
            if (unread > 0) ...[
              const SizedBox(width: 8),
              _Badge(count: unread, highlighted: mentions > 0),
            ],
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        // A mention is worth interrupting for; ambient chatter is not.
        color: highlighted ? Tokens.accent : Tokens.badge,
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: TextStyle(
          color: highlighted ? Tokens.bg : Tokens.text,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
