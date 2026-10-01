import 'package:flutter/material.dart';

import '../model/people.dart';
import '../rust/api/types.dart';
import '../theme.dart';
import 'avatar.dart';
import 'menu.dart';
import 'motion.dart';
import 'nick_color.dart';
import 'touchable.dart';

/// Channel members, ordered by privilege then name (the core sorts them).
///
/// Stateful only to notice arrivals. Nothing else here needs to remember
/// anything, but a nick appearing out of nowhere in a list you were reading is
/// the sort of change that is easy to miss entirely, so the row fades in.
///
/// Departures are still instant. Animating one means holding a row that no
/// longer exists in the model until its exit finishes, which is a much larger
/// change than it looks — and a nick vanishing is the less startling half of
/// the pair, with the member count moving to confirm it.
class MemberList extends StatefulWidget {
  const MemberList({
    super.key,
    required this.members,
    this.onClose,
    this.onOpenDirect,
    this.colorNicks = true,
    this.self,
    this.profileId,
    this.onEditPerson,
  });

  final List<MemberView> members;
  final VoidCallback? onClose;

  /// Whether each nick wears its [NickPalette] colour. Passed in rather than
  /// read from the settings scope so the list can stand on its own.
  final bool colorNicks;

  /// Our own nick, which keeps the accent here as it does on its messages.
  final String? self;

  /// Which network these people are on, for what the user has written about
  /// them. Null draws everyone as the server names them.
  final String? profileId;

  /// Open what the user has written about one of them. Offered on the row's
  /// context menu, so the tap stays what it was: a conversation.
  final ValueChanged<String>? onEditPerson;

  /// Open a conversation with one of them.
  ///
  /// A roster you can only read is a list of names; the whole reason to know
  /// who is in a channel is to be able to say something to one of them.
  final ValueChanged<String>? onOpenDirect;

  @override
  State<MemberList> createState() => _MemberListState();
}

class _MemberListState extends State<MemberList> {
  Set<String> _known = {};
  Set<String> _fresh = {};

  @override
  void initState() {
    super.initState();
    // Whoever is already here on the first frame was not watched arriving.
    _known = {for (final m in widget.members) m.nick};
  }

  @override
  void didUpdateWidget(MemberList old) {
    super.didUpdateWidget(old);
    // The roster is replaced wholesale or not at all — the core sends a full
    // list, never a delta — so identity is an exact answer to "did anyone
    // arrive". Without this guard every repaint of the session, including one
    // caused by a message in a different channel, rebuilt two sets of every
    // nick in the channel. In `#Debian` that is 1,766 string hashes to
    // discover that nothing happened.
    if (identical(old.members, widget.members)) return;

    final now = {for (final m in widget.members) m.nick};
    _fresh = now.difference(_known);
    _known = now;
    if (_fresh.isEmpty) return;
    // Spent on the frame it was set. Rows off screen are not built in that
    // frame and so never animate, which is right — scrolling down to someone
    // who joined a minute ago is not an arrival. Mutated rather than set with
    // setState: it only ever affects the next build, and asking for one here
    // would loop.
    WidgetsBinding.instance.addPostFrameCallback((_) => _fresh = const {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final members = widget.members;
    return Container(
      color: t.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(
              14,
              14,
              widget.onClose == null ? 14 : 6,
              13,
            ),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: t.rule, width: Tokens.hairline),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: AnimatedSwitcher(
                    duration: context.motion.normal,
                    switchInCurve: Motion.curve,
                    switchOutCurve: Motion.exit,
                    child: Text(
                      // Keyed on the number, so the count cross-fades when it
                      // changes. It is the only acknowledgement that someone
                      // left, so it should not simply flick over.
                      key: ValueKey(members.length),
                      '${members.length} '
                      '${members.length == 1 ? 'member' : 'members'}',
                      style: TextStyle(
                        color: t.muted,
                        fontSize: 12,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ),
                if (widget.onClose != null)
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close, size: 18),
                    color: t.muted,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          Expanded(
            child: members.isEmpty
                ? Center(
                    child: Text(
                      'No members yet.',
                      style: TextStyle(color: t.faint, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: members.length,
                    itemBuilder: (context, i) => _MemberRow(
                      // Keyed by nick, not by index. Without this a member
                      // leaving hands their row to the next person down, and
                      // the away animation would run between two different
                      // people's states.
                      key: ValueKey(members[i].nick),
                      member: members[i],
                      fresh: _fresh.contains(members[i].nick),
                      colorNicks: widget.colorNicks,
                      isSelf:
                          widget.self != null &&
                          members[i].nick.toLowerCase() ==
                              widget.self!.toLowerCase(),
                      card: widget.profileId == null
                          ? null
                          : People.instance.of(
                              widget.profileId!,
                              members[i].nick,
                            ),
                      onEdit: widget.onEditPerson == null
                          ? null
                          : () => widget.onEditPerson!(members[i].nick),
                      onTap: widget.onOpenDirect == null
                          ? null
                          : () => widget.onOpenDirect!(members[i].nick),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.fresh,
    required this.colorNicks,
    required this.isSelf,
    this.card,
    this.onTap,
    this.onEdit,
  });

  final MemberView member;
  final bool fresh;
  final bool colorNicks;
  final bool isSelf;

  /// What the user has written about this person, if anything.
  final PersonCard? card;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;

  Future<void> _menu(BuildContext context, Offset at) async {
    final action = await showPointerMenu<String>(
      context,
      at: at,
      items: [
        if (onTap != null)
          const PopupMenuItem(
            value: 'message',
            child: MenuRow(icon: Icons.chat_bubble_outline, label: 'Message'),
          ),
        const PopupMenuItem(
          value: 'edit',
          child: MenuRow(icon: Icons.person_outline, label: 'Profile…'),
        ),
      ],
    );
    switch (action) {
      case 'message':
        onTap?.call();
      case 'edit':
        onEdit?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final prefix = member.prefix;
    // Away members recede rather than disappear — still readable, clearly
    // secondary. Animated because it is a colour changing in place on a row
    // that is not otherwise moving, which is exactly what `fast` is for.
    final away = member.away;
    final fade = context.motion.fast;

    return Arrive(
      play: fresh,
      child: Touchable(
        onTap: onTap,
        onContextMenu: onEdit == null ? null : (at) => _menu(context, at),
        builder: (context, touch) => Container(
          // The row's own press and hover wash, as everywhere else — the theme
          // removes Material's ripple, so feedback has to be painted here.
          color: t.surfaceHover.withValues(alpha: touch.wash),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              // A fixed gutter keeps every nick left-aligned whether or not it
              // carries a prefix, so the column reads cleanly.
              SizedBox(
                width: 12,
                child: AnimatedDefaultTextStyle(
                  duration: fade,
                  curve: Motion.curve,
                  style: TextStyle(
                    color: away ? t.faint : t.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  child: Text(prefix ?? ''),
                ),
              ),
              if (card?.hasPicture ?? false) ...[
                Avatar(card: card, size: 18),
                const SizedBox(width: 7),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedDefaultTextStyle(
                      duration: fade,
                      curve: Motion.curve,
                      overflow: TextOverflow.ellipsis,
                      // Away dims to the same grey for everyone: someone who
                      // is not here has stepped out of the colour scheme too.
                      // A colour the user chose comes before the one the nick
                      // hashes to; nothing comes before away.
                      style: TextStyle(
                        color: away
                            ? t.faint
                            : isSelf
                            ? t.accent
                            : card?.color ??
                                  (colorNicks
                                      ? NickPalette.of(member.nick, t)
                                      : t.text),
                        fontSize: 13,
                        fontStyle: away ? FontStyle.italic : FontStyle.normal,
                      ),
                      // The name the user gave them, if any. The nick itself
                      // is one hover away, and always in the dialog.
                      child: Tooltip(
                        message: card?.alias == null ? '' : member.nick,
                        child: Text(card?.alias ?? member.nick),
                      ),
                    ),
                    if (card?.note case final note?)
                      Text(
                        note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.faint, fontSize: 11),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
