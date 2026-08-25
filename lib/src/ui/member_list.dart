import 'package:flutter/material.dart';

import '../rust/api/types.dart';
import '../theme.dart';
import 'motion.dart';

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
  const MemberList({super.key, required this.members, this.onClose});

  final List<MemberView> members;
  final VoidCallback? onClose;

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
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({super.key, required this.member, required this.fresh});

  final MemberView member;
  final bool fresh;

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
      child: Padding(
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
            Expanded(
              child: AnimatedDefaultTextStyle(
                duration: fade,
                curve: Motion.curve,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: away ? t.faint : t.text,
                  fontSize: 13,
                  fontStyle: away ? FontStyle.italic : FontStyle.normal,
                ),
                child: Text(member.nick),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
