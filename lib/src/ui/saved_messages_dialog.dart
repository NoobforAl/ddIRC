import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../model/marks.dart';
import '../model/profile.dart';
import '../model/settings.dart';
import '../rust/api/store.dart' as store;
import '../theme.dart';
import 'settings/settings_chrome.dart';

/// Every message the user saved, on every network, most recently saved first.
///
/// A list of their own, the way a messenger keeps one: somewhere to put the
/// address someone pasted, the command that fixed it, the thing to read
/// later. Each is a copy, so it is still here after the conversation it came
/// from has scrolled out of the history.
///
/// Opening one goes to it, when it is on the network this screen is for —
/// another network's conversation is behind another connection, and this
/// list can show it, copy it and forget it, but not take you there.
class SavedMessagesDialog extends StatelessWidget {
  const SavedMessagesDialog({
    super.key,
    required this.profileId,
    required this.onOpen,
  });

  /// The network on screen; its messages can be opened in place.
  final String profileId;
  final ValueChanged<store.Mark> onOpen;

  static Future<void> show(
    BuildContext context, {
    required String profileId,
    required ValueChanged<store.Mark> onOpen,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => SavedMessagesDialog(profileId: profileId, onOpen: onOpen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final settings = SettingsScope.of(context);
    final profiles = ProfileScope.of(context);

    return ListenableBuilder(
      listenable: Marks.instance,
      builder: (context, _) {
        final saved = Marks.instance.saved;
        return SettingsDialog(
          title: 'Saved messages',
          subtitle: saved.isEmpty
              ? 'Nothing saved yet'
              : '${saved.length} saved',
          children: [
            if (saved.isEmpty)
              const SettingsNote(
                text:
                    'Hold a message — or right-click it — and choose Save to '
                    'keep it here.',
              ),
            for (final mark in saved)
              _SavedRow(
                mark: mark,
                where:
                    '${mark.conversation} · '
                    '${profiles.byId(mark.profileId)?.name ?? 'a deleted network'}',
                when: () {
                  final at = DateTime.fromMillisecondsSinceEpoch(mark.atMs);
                  return '${AppSettings.describeDay(at)} '
                      '${settings.formatTime(at)}';
                }(),
                tokens: t,
                onOpen: mark.profileId == profileId
                    ? () {
                        Navigator.of(context).pop();
                        onOpen(mark);
                      }
                    : null,
              ),
          ],
        );
      },
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    required this.mark,
    required this.where,
    required this.when,
    required this.tokens,
    this.onOpen,
  });

  final store.Mark mark;
  final String where;
  final String when;
  final Tokens tokens;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final text = Marks.plainText(mark.spans);
    return ListTile(
      dense: true,
      onTap: onOpen,
      title: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${mark.sender ?? ''}  ',
              style: TextStyle(color: t.accent, fontWeight: FontWeight.w600),
            ),
            TextSpan(text: text),
          ],
        ),
        maxLines: 4,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: t.text, fontSize: 13),
      ),
      subtitle: Text(
        '$where · $when',
        style: TextStyle(color: t.muted, fontSize: 11.5),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('Message copied'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            icon: const Icon(Icons.copy_rounded, size: 17),
            color: t.muted,
            tooltip: 'Copy',
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            onPressed: () => Marks.instance.remove(mark),
            icon: const Icon(Icons.bookmark_remove_outlined, size: 18),
            color: t.muted,
            tooltip: 'Remove from saved',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}
