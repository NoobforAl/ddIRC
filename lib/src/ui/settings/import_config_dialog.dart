import 'package:flutter/material.dart';

import '../../model/profile.dart';
import '../../theme.dart';
import '../motion.dart';
import '../touchable.dart';
import 'settings_chrome.dart';

/// What a `.irc` file or a scanned QR code named, waiting to be saved.
///
/// One dialog for both sources, because the moment either has handed over
/// text that `parseIrcConfig` accepted, a file and a QR code are the same
/// thing: a list of networks nobody has agreed to add yet. Nothing is saved
/// by parsing alone — this is where that agreement happens, network by
/// network, the same way the network picker hands the profile editor an
/// address rather than committing one on the user's behalf.
class ImportConfigDialog extends StatefulWidget {
  const ImportConfigDialog({super.key, required this.networks});

  /// Already parsed, and already carrying a fresh id each — see
  /// `parseIrcConfig`. This dialog only decides which of them get saved.
  final List<Profile> networks;

  /// Returns how many were actually saved, so the caller can say so.
  static Future<int> show(BuildContext context, List<Profile> networks) async {
    final imported = await showDialog<int>(
      context: context,
      builder: (_) => ImportConfigDialog(networks: networks),
    );
    return imported ?? 0;
  }

  @override
  State<ImportConfigDialog> createState() => _ImportConfigDialogState();
}

class _ImportConfigDialogState extends State<ImportConfigDialog> {
  /// Every network starts checked. A file somebody chose to import, or a QR
  /// code they chose to scan, is already the deliberate step — asking again
  /// per network would be asking the same question twice for no reason a
  /// shared file with one bad entry does not already cover by being
  /// uncheckable here.
  late final Set<String> _selected = widget.networks.map((n) => n.id).toSet();

  bool _busy = false;

  Future<void> _import() async {
    if (_selected.isEmpty) return;
    setState(() => _busy = true);

    final store = ProfileScope.of(context);
    var saved = 0;
    for (final network in widget.networks) {
      if (!_selected.contains(network.id)) continue;
      await store.save(network);
      saved++;
    }

    if (!mounted) return;
    Navigator.of(context).pop(saved);
  }

  @override
  Widget build(BuildContext context) {
    final networks = widget.networks;
    return SettingsDialog(
      title: networks.length == 1 ? 'Import a network' : 'Import networks',
      subtitle: networks.length == 1
          ? networks.single.name
          : '${networks.length} found',
      children: [
        for (final network in networks)
          _NetworkCheckRow(
            profile: network,
            selected: _selected.contains(network.id),
            onTap: () => setState(() {
              if (!_selected.remove(network.id)) _selected.add(network.id);
            }),
          ),
        const SettingsProse(
          'Every password stays where it already is — none was in the file '
          'to begin with. Each network still opens in the editor before it '
          'connects to anything.',
        ),
        const SettingsRule(),
        SettingsActions(
          children: [
            SettingsTertiaryButton(
              label: 'Cancel',
              onPressed: _busy ? null : () => Navigator.of(context).pop(0),
            ),
            SettingsPrimaryButton(
              label: _busy
                  ? 'Importing…'
                  : _selected.length == networks.length
                  ? 'Import ${_selected.length}'
                  : 'Import ${_selected.length} of ${networks.length}',
              onPressed: _busy || _selected.isEmpty ? null : _import,
            ),
          ],
        ),
        const SizedBox(height: 6),
      ],
    );
  }
}

/// One network in the list, with the box that decides whether it is kept.
class _NetworkCheckRow extends StatelessWidget {
  const _NetworkCheckRow({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final Profile profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final m = context.motion;

    return Touchable(
      onTap: onTap,
      builder: (context, touch) => AnimatedContainer(
        duration: m.fast,
        curve: Motion.curve,
        color: t.surfaceHover.withValues(alpha: touch.wash),
        padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
        child: Row(
          children: [
            AnimatedContainer(
              duration: m.fast,
              curve: Motion.curve,
              width: 17,
              height: 17,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? t.accent : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: selected ? t.accent : t.rule,
                  width: selected ? 1 : Tokens.hairline,
                ),
              ),
              child: Appear(
                child: selected
                    ? Icon(
                        Icons.check,
                        key: const ValueKey('check'),
                        size: 12,
                        color: t.onAccent,
                      )
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    profile.name,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: t.text,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${profile.host}:${profile.port} · ${profile.nickname}',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
