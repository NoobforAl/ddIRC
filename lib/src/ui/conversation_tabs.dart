import 'package:flutter/material.dart';

import '../model/session.dart';
import '../theme.dart';
import 'layout.dart';
import 'motion.dart';
import 'touchable.dart';

/// Height of the strip. Tuned to the header above it rather than to the tabs.
const double _tabHeight = 34;

/// The open conversations, as a strip above the conversation itself.
///
/// The same distinction an editor draws between its file tree and its tabs:
/// the list on the left is every channel you are in, this is the handful you
/// are actually working in. Closing a tab does not leave the channel — you
/// stay joined and the backlog stays intact; the list on the left is where you
/// go to leave, or to open it again.
///
/// Hidden below two tabs. With one conversation open there is nothing to
/// switch between, and the header directly above already names it.
class ConversationTabs extends StatelessWidget {
  const ConversationTabs({
    super.key,
    required this.session,
    required this.onSelect,
    required this.onClose,
  });

  final SessionModel session;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final tabs = session.tabs;
    final active = session.active;

    return Reveal(
      child: tabs.length < 2
          ? null
          : Container(
              height: _tabHeight,
              decoration: BoxDecoration(
                color: t.surface,
                border: Border(
                  bottom: BorderSide(color: t.rule, width: Tokens.hairline),
                ),
              ),
              // Scrolls rather than shrinking: a tab narrowed to nothing is
              // not a tab, and a channel name truncated to two characters
              // cannot be told from its neighbour.
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: tabs.length,
                itemBuilder: (context, i) {
                  final conversation = tabs[i];
                  return _Tab(
                    conversation: conversation,
                    selected: identical(conversation, active),
                    onSelect: () => onSelect(conversation.name),
                    onClose: () => onClose(conversation.name),
                  );
                },
              ),
            ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.conversation,
    required this.selected,
    required this.onSelect,
    required this.onClose,
  });

  final Conversation conversation;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;
    final unread = conversation.unread;

    return Touchable(
      onTap: onSelect,
      // Middle-click closes in every editor; there is no middle button here,
      // so the secondary one does it.
      onSecondaryTap: onClose,
      builder: (context, touch) => AnimatedContainer(
        duration: m.normal,
        curve: Motion.curve,
        constraints: BoxConstraints(maxWidth: context.layout.tabMaxWidth),
        decoration: BoxDecoration(
          color: selected
              ? t.surfaceHover
              : t.surfaceHover.withValues(alpha: touch.wash),
          border: Border(
            // A rule along the top, where the channel list puts one down the
            // leading edge. Same language, turned through ninety degrees.
            top: BorderSide(
              color: selected ? t.accent : Colors.transparent,
              width: 2,
            ),
            right: BorderSide(color: t.rule, width: Tokens.hairline),
          ),
        ),
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: AnimatedDefaultTextStyle(
                duration: m.normal,
                curve: Motion.curve,
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: selected ? t.text : (unread > 0 ? t.text : t.muted),
                  fontSize: 12.5,
                  fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.w400,
                ),
                child: Text(conversation.name, overflow: TextOverflow.ellipsis),
              ),
            ),
            Appear(
              child: unread > 0
                  ? Padding(
                      key: const ValueKey('badge'),
                      padding: const EdgeInsets.only(left: 7),
                      child: _Count(
                        count: unread,
                        highlighted: conversation.unreadMentions > 0,
                      ),
                    )
                  : null,
            ),
            // The slot is always there and only its contents fade, so tabs do
            // not shuffle sideways as the pointer crosses them.
            SizedBox(
              width: 26,
              child: AnimatedOpacity(
                duration: m.fast,
                curve: Motion.curve,
                // The two tabs worth offering to close: the one under the
                // pointer, and the one you are in.
                opacity: selected || touch != Touch.none ? 1 : 0,
                child: _CloseButton(onTap: onClose),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  const _CloseButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Center(
      child: Touchable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        builder: (context, touch) => AnimatedContainer(
          duration: context.motion.fast,
          curve: Motion.curve,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: t.rule.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(
            Icons.close,
            size: 13,
            color: touch == Touch.none ? t.faint : t.text,
          ),
        ),
      ),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.count, required this.highlighted});

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
