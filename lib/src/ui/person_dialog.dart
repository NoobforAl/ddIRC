import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../model/history.dart';
import '../model/people.dart';
import '../theme.dart';
import 'avatar.dart';
import 'nick_color.dart';
import 'settings/settings_chrome.dart';
import 'touchable.dart';

/// What the user wants to remember about one person: a name for them, a
/// note, a colour, a picture. Opened from the member list and from a name
/// in the scrollback.
///
/// Nothing here is sent anywhere. It is the user's own annotation, kept on
/// this machine, and only kept past exit when message history is on — the
/// dialog says which of the two it is doing, because a note that quietly
/// vanished tomorrow would be worse than one never taken.
class PersonDialog extends StatefulWidget {
  const PersonDialog({super.key, required this.profileId, required this.nick});

  final String profileId;
  final String nick;

  static Future<void> show(
    BuildContext context, {
    required String profileId,
    required String nick,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => PersonDialog(profileId: profileId, nick: nick),
    );
  }

  @override
  State<PersonDialog> createState() => _PersonDialogState();
}

class _PersonDialogState extends State<PersonDialog> {
  late final TextEditingController _alias;
  late final TextEditingController _note;
  late PersonCard _card;

  /// What was there when the dialog opened, so Remove can be offered only
  /// when there is something to remove.
  late final bool _existed;

  @override
  void initState() {
    super.initState();
    final card = People.instance.of(widget.profileId, widget.nick);
    _existed = card != null;
    _card = card ?? const PersonCard();
    _alias = TextEditingController(text: _card.alias ?? '');
    _note = TextEditingController(text: _card.note ?? '');
  }

  @override
  void dispose() {
    _alias.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picked = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'Images',
          extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
        ),
      ],
    );
    if (picked == null) return;
    final shrunk = await shrinkAvatar(await picked.readAsBytes());
    if (!mounted) return;
    if (shrunk == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('That file is not an image ddIRC can read.'),
        ),
      );
      return;
    }
    setState(() {
      _card = _card.copyWith(avatar: shrunk, pixelSeed: null);
    });
  }

  void _save() {
    String? trimmed(String text) {
      final value = text.trim();
      return value.isEmpty ? null : value;
    }

    People.instance.set(
      widget.profileId,
      widget.nick,
      _card.copyWith(alias: trimmed(_alias.text), note: trimmed(_note.text)),
    );
    Navigator.of(context).pop();
  }

  void _remove() {
    People.instance.set(widget.profileId, widget.nick, const PersonCard());
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final kept = MessageHistory.instance.enabled;

    return SettingsDialog(
      title: widget.nick,
      subtitle: kept
          ? 'Kept on this machine, with your message history.'
          : 'Kept until ddIRC closes. Turn on message history to keep it.',
      children: [
        SettingsSection(
          label: 'Name',
          children: [
            SettingsLabelledField(
              label: 'Shown as',
              hint: widget.nick,
              help:
                  'Replaces the nick wherever it appears, for you only. '
                  'Leave empty to show the nick.',
              controller: _alias,
              onSubmitted: (_) => _save(),
            ),
            SettingsLabelledField(
              label: 'Note',
              hint: 'Who this is, or anything worth remembering',
              controller: _note,
              onSubmitted: (_) => _save(),
            ),
          ],
        ),
        SettingsSection(
          label: 'Colour',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: _ColourPicker(
                nick: widget.nick,
                chosen: _card.color,
                onChanged: (color) =>
                    setState(() => _card = _card.copyWith(color: color)),
              ),
            ),
          ],
        ),
        SettingsSection(
          label: 'Picture',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: Row(
                children: [
                  _card.hasPicture
                      ? Avatar(card: _card, size: 40)
                      : Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                              color: t.rule,
                              width: Tokens.hairline,
                            ),
                          ),
                        ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        SettingsSecondaryButton(
                          label: 'Choose image…',
                          onPressed: _pickImage,
                        ),
                        SettingsSecondaryButton(
                          label: 'Random pixels',
                          onPressed: () => setState(
                            () => _card = _card.copyWith(
                              avatar: null,
                              pixelSeed: PixelAvatarPainter.roll(),
                            ),
                          ),
                        ),
                        if (_card.hasPicture)
                          SettingsTertiaryButton(
                            label: 'None',
                            onPressed: () => setState(
                              () => _card = _card.copyWith(
                                avatar: null,
                                pixelSeed: null,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsActions(
          children: [
            if (_existed)
              SettingsDangerButton(label: 'Remove', onPressed: _remove),
            SettingsPrimaryButton(label: 'Save', onPressed: _save),
          ],
        ),
      ],
    );
  }
}

/// The twelve colours a nick can wear, plus the one it wears by itself.
class _ColourPicker extends StatelessWidget {
  const _ColourPicker({
    required this.nick,
    required this.chosen,
    required this.onChanged,
  });

  final String nick;
  final Color? chosen;
  final ValueChanged<Color?> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final palette = t.brightness == Brightness.dark
        ? NickPalette.dark
        : NickPalette.light;
    final automatic = NickPalette.of(nick, t);

    Widget swatch(Color color, {required bool selected, String? label}) {
      return Touchable(
        onTap: () => onChanged(label == null ? color : null),
        borderRadius: BorderRadius.circular(Tokens.radiusS),
        builder: (context, touch) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
          decoration: BoxDecoration(
            color: selected
                ? t.surfaceHover
                : t.surfaceHover.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(Tokens.radiusS),
            border: Border.all(
              color: selected ? t.accent : t.rule,
              width: selected ? 1 : Tokens.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              if (label != null) ...[
                const SizedBox(width: 6),
                Text(label, style: TextStyle(color: t.text, fontSize: 12)),
              ],
            ],
          ),
        ),
      );
    }

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        swatch(automatic, selected: chosen == null, label: 'Automatic'),
        for (final color in palette) swatch(color, selected: chosen == color),
      ],
    );
  }
}
