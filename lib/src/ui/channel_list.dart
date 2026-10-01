import 'package:flutter/material.dart';

import '../model/chat_state.dart';
import '../model/history.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../theme.dart';
import 'count_badge.dart';
import 'menu.dart';
import 'motion.dart';
import 'touchable.dart';

/// How long a conversation can be muted for from its menu, and what the
/// choice is called. Null is muting with no end.
const muteDurations = <(String, Duration?)>[
  ('For 1 hour', Duration(hours: 1)),
  ('For 8 hours', Duration(hours: 8)),
  ('For 1 day', Duration(days: 1)),
  ('For 1 week', Duration(days: 7)),
  ('Until I unmute it', null),
];

/// Joined channels and open conversations, with unread counts.
///
/// Pinned conversations first, in the order they were pinned; then the rest
/// as they were opened; then, folded away at the bottom, the archived — still
/// joined, still collecting messages, out of the way until somebody says
/// their name.
class ChannelList extends StatefulWidget {
  const ChannelList({
    super.key,
    required this.session,
    required this.networkName,
    required this.onSelect,
    required this.onBrowse,
    this.onDisconnect,
    this.onChannelSettings,
  });

  final SessionModel session;

  /// What the user named this network, used until the server names itself.
  final String networkName;
  final ValueChanged<String> onSelect;

  /// Opens the server's own list of channels.
  ///
  /// The answer to the empty state's old advice, which was to type a command
  /// naming a channel — useful only to somebody who already knew one.
  final VoidCallback onBrowse;

  final VoidCallback? onDisconnect;

  /// Opens the settings for one conversation, from its menu.
  final ValueChanged<Conversation>? onChannelSettings;

  @override
  State<ChannelList> createState() => _ChannelListState();
}

class _ChannelListState extends State<ChannelList> {
  bool _showArchived = false;

  SessionModel get session => widget.session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Drafts, pins and archives change from elsewhere — the composer, this
    // list's own menu — and the history switch decides whether the last two
    // are offered at all.
    listenable: Listenable.merge([
      ConversationStates.instance,
      MessageHistory.instance,
    ]),
    builder: (context, _) => _build(context),
  );

  /// What right-click or a long press on a row offers.
  Future<void> _menu(Conversation conversation, Offset at) async {
    final states = ConversationStates.instance;
    final settings = SettingsScope.of(context);
    final profileId = session.profileId;
    final available = states.available;
    final pinned = states.isPinned(profileId, conversation.name);
    final archived = states.isArchived(profileId, conversation.name);
    final muted =
        settings.notifyFor(profileId, conversation.name) == NotifyLevel.none;

    final choice = await showPointerMenu<String>(
      context,
      at: at,
      items: [
        PopupMenuItem(
          value: 'pin',
          enabled: available,
          child: MenuRow(
            icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
            label: pinned ? 'Unpin' : 'Pin to top',
            enabled: available,
          ),
        ),
        PopupMenuItem(
          value: 'archive',
          enabled: available,
          child: MenuRow(
            icon: archived ? Icons.unarchive_outlined : Icons.archive_outlined,
            label: archived ? 'Unarchive' : 'Archive',
            enabled: available,
          ),
        ),
        if (!available)
          const PopupMenuItem(
            enabled: false,
            height: 28,
            child: Text(
              'Turn on message history in Privacy to pin and archive',
              style: TextStyle(fontSize: 11.5),
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'mute',
          child: MenuRow(
            icon: muted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            label: muted ? 'Unmute' : 'Mute…',
          ),
        ),
        if (conversation.unread > 0)
          const PopupMenuItem(
            value: 'read',
            child: MenuRow(icon: Icons.done_all_rounded, label: 'Mark as read'),
          ),
        if (widget.onChannelSettings != null)
          const PopupMenuItem(
            value: 'settings',
            child: MenuRow(icon: Icons.tune, label: 'Settings…'),
          ),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'pin':
        states.setPinned(profileId, conversation.name, !pinned);
      case 'archive':
        states.setArchived(profileId, conversation.name, !archived);
        // Archiving the one on screen does not close it; it only stops it
        // standing in the list. Unarchiving shows the group it came from.
        if (archived) setState(() => _showArchived = false);
      case 'mute':
        if (muted) {
          settings.setNotifyFor(profileId, conversation.name, NotifyLevel.all);
          return;
        }
        final duration = await showPointerMenu<int>(
          context,
          at: at,
          items: [
            for (var i = 0; i < muteDurations.length; i++)
              PopupMenuItem(value: i, child: Text(muteDurations[i].$1)),
          ],
        );
        if (duration == null || !mounted) return;
        settings.muteFor(
          profileId,
          conversation.name,
          muteDurations[duration].$2,
        );
      case 'read':
        session.markRead(conversation.name);
      case 'settings':
        widget.onChannelSettings?.call(conversation);
    }
  }

  Widget _row(Conversation conversation, Conversation? active) {
    final settings = SettingsScope.of(context);
    final states = ConversationStates.instance;
    final profileId = session.profileId;
    final level = settings.notifyFor(profileId, conversation.name);
    final until = settings.mutedUntil(profileId, conversation.name);
    // The one on screen shows its draft in the composer; the list only
    // needs to remind you of the ones you are not looking at.
    final draft = identical(conversation, active)
        ? null
        : states.draftOf(profileId, conversation.name);
    return _ChannelRow(
      key: ValueKey(conversation.name),
      conversation: conversation,
      selected: identical(conversation, active),
      onTap: () => widget.onSelect(conversation.name),
      onMenu: (at) => _menu(conversation, at),
      muted: level == NotifyLevel.none,
      mutedUntil: until == null ? null : settings.formatTime(until),
      pinned: states.isPinned(profileId, conversation.name),
      draft: draft,
    );
  }

  Widget _build(BuildContext context) {
    final t = context.tokens;
    final arranged = ConversationStates.instance.arrange(
      session.profileId,
      session.conversations,
    );
    final conversations = arranged.shown;
    final archived = arranged.archived;
    final active = session.active;
    // Read here rather than per row, so changing a channel's level in the
    // dialog repaints the whole list rather than one stale row.
    SettingsScope.of(context);

    return Container(
      color: t.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _header(t),
          Expanded(
            child: conversations.isEmpty && archived.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            'Nothing joined yet.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: t.faint,
                              fontSize: 12,
                              height: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // A button rather than the name of a command. The
                        // people who reach this screen are exactly the ones
                        // who do not yet know a channel to type.
                        TextButton.icon(
                          onPressed: widget.onBrowse,
                          icon: const Icon(Icons.travel_explore, size: 16),
                          label: const Text('Browse channels'),
                          style: TextButton.styleFrom(
                            foregroundColor: t.accent,
                            textStyle: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      for (final conversation in conversations)
                        _row(conversation, active),
                      if (archived.isNotEmpty)
                        _ArchivedHeader(
                          count: archived.length,
                          unread: archived.fold(0, (n, c) => n + c.unread),
                          open: _showArchived,
                          onTap: () =>
                              setState(() => _showArchived = !_showArchived),
                        ),
                      if (_showArchived)
                        for (final conversation in archived)
                          _row(conversation, active),
                    ],
                  ),
          ),
          if (widget.onDisconnect != null) _footer(t),
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
                  session.network ?? widget.networkName,
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
          // Beside the network's name, because browsing is a question about
          // the network rather than about anything already in the list below.
          IconButton(
            onPressed: widget.onBrowse,
            icon: const Icon(Icons.travel_explore, size: 18),
            color: t.muted,
            visualDensity: VisualDensity.compact,
            tooltip: 'Browse this network’s channels',
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
        onPressed: widget.onDisconnect,
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

/// The fold the archived conversations sit behind, with how many there are
/// and whether any of them has something unread.
class _ArchivedHeader extends StatelessWidget {
  const _ArchivedHeader({
    required this.count,
    required this.unread,
    required this.open,
    required this.onTap,
  });

  final int count;
  final int unread;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Touchable(
      onTap: onTap,
      builder: (context, touch) => Container(
        margin: const EdgeInsets.fromLTRB(8, 6, 8, 1),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Tokens.radiusM),
          color: t.surfaceHover.withValues(alpha: touch.wash),
        ),
        child: Row(
          children: [
            Icon(Icons.archive_outlined, size: 15, color: t.muted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Archived ($count)',
                style: TextStyle(color: t.muted, fontSize: 12.5),
              ),
            ),
            if (unread > 0 && !open)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: CountBadge(count: unread),
              ),
            Icon(
              open ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 18,
              color: t.muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onTap,
    required this.onMenu,
    required this.muted,
    this.mutedUntil,
    this.pinned = false,
    this.draft,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onMenu;
  final bool muted;

  /// When a timed mute ends, as the clock shows it.
  final String? mutedUntil;
  final bool pinned;

  /// Text typed here and not sent, shown under the name.
  final String? draft;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    final unread = conversation.unread;
    final mentions = conversation.unreadMentions;

    return Touchable(
      onTap: onTap,
      // Right-click on desktop, long-press on touch: what can be done with
      // this conversation — pin it, put it away, quiet it, open its settings
      // — without a per-row button cluttering the list.
      onContextMenu: onMenu,
      builder: (context, touch) => AnimatedContainer(
        duration: m.normal,
        curve: Motion.curve,
        // The active channel is a soft pill: inset from the edges, rounded,
        // and tinted with the accent rather than marked with a rule. It slides
        // down the list as selection moves, so the eye can follow it. Tall
        // enough to hit with a thumb without aiming.
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(Tokens.radiusM),
          // Hover shares the surface colour and selection takes the accent,
          // so the pointer can preview a row without impersonating the one
          // the user is already in.
          color: selected
              ? Color.alphaBlend(
                  t.accent.withValues(alpha: 0.14 + 0.06 * touch.wash),
                  t.surface,
                )
              : t.surfaceHover.withValues(alpha: touch.wash),
        ),
        padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
        child: Row(
          children: [
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: m.normal,
                curve: Motion.curve,
                // Merged onto the ambient style rather than replacing it, so
                // the row keeps whatever font the theme is handing down.
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: selected ? t.accent : (unread > 0 ? t.text : t.muted),
                  fontSize: 14,
                  // Weight is what says "someone spoke here", so it is worth
                  // interpolating instead of snapping between two rows.
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
                child: draft == null
                    ? Text(conversation.name, overflow: TextOverflow.ellipsis)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            conversation.name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: 'Draft: ',
                                  style: TextStyle(color: t.bad),
                                ),
                                TextSpan(
                                  text: draft!.replaceAll('\n', ' '),
                                  style: TextStyle(color: t.muted),
                                ),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            if (pinned)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Icon(Icons.push_pin, size: 12, color: t.faint),
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
                      child: Tooltip(
                        message: mutedUntil == null
                            ? 'Muted'
                            : 'Muted until $mutedUntil',
                        child: Icon(
                          Icons.notifications_off_outlined,
                          size: 13,
                          color: t.faint,
                        ),
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
                      child: CountBadge(
                        count: unread,
                        highlighted: mentions > 0,
                      ),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
