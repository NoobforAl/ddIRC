import 'package:flutter/material.dart';

import '../rust/api/types.dart';
import '../theme.dart';

/// Channel members, ordered by privilege then name (the core sorts them).
class MemberList extends StatelessWidget {
  const MemberList({super.key, required this.members, this.onClose});

  final List<MemberView> members;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Tokens.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: EdgeInsets.fromLTRB(14, 14, onClose == null ? 14 : 6, 13),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Tokens.rule, width: Tokens.hairline),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${members.length} ${members.length == 1 ? 'member' : 'members'}',
                    style: const TextStyle(
                      color: Tokens.muted,
                      fontSize: 12,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
                if (onClose != null)
                  IconButton(
                    onPressed: onClose,
                    icon: const Icon(Icons.close, size: 18),
                    color: Tokens.muted,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          Expanded(
            child: members.isEmpty
                ? const Center(
                    child: Text(
                      'No members yet.',
                      style: TextStyle(color: Tokens.faint, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: members.length,
                    itemBuilder: (context, i) => _MemberRow(member: members[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({required this.member});

  final MemberView member;

  @override
  Widget build(BuildContext context) {
    final prefix = member.prefix;
    // Away members recede rather than disappear — still readable, clearly
    // secondary.
    final color = member.away ? Tokens.faint : Tokens.text;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          // A fixed gutter keeps every nick left-aligned whether or not it
          // carries a prefix, so the column reads cleanly.
          SizedBox(
            width: 12,
            child: Text(
              prefix ?? '',
              style: TextStyle(
                color: member.away ? Tokens.faint : Tokens.accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              member.nick,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontStyle: member.away ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
