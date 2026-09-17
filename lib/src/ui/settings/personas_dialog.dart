import 'package:flutter/material.dart';

import '../../model/history.dart';
import '../../model/personas.dart';
import '../../theme.dart';
import '../touchable.dart';
import 'settings_chrome.dart';

/// Where the user makes and keeps their identities.
///
/// A profile here is a name the user keeps for themselves — the network never
/// sees it. What a network sees is a throwaway nick, one per network, so the
/// same person is unlinkable across servers. This is the home for making them,
/// renaming them, and seeing which handle each one has picked up where.
class PersonasDialog extends StatefulWidget {
  const PersonasDialog({super.key});

  static Future<void> show(BuildContext context) => showDialog<void>(
    context: context,
    builder: (_) => const PersonasDialog(),
  );

  @override
  State<PersonasDialog> createState() => _PersonasDialogState();
}

class _PersonasDialogState extends State<PersonasDialog> {
  final _new = TextEditingController();

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final label = _new.text.trim();
    if (label.isEmpty) return;
    await Personas.instance.create(label);
    if (!mounted) return;
    _new.clear();
    setState(() {});
  }

  Future<void> _rename(Persona persona) async {
    final name = await askPersonaName(
      context,
      title: 'Rename profile',
      initial: persona.label,
      saveLabel: 'Save',
    );
    if (name == null || name.isEmpty) return;
    await Personas.instance.rename(persona.id, name);
    if (mounted) setState(() {});
  }

  Future<void> _delete(Persona persona) async {
    final yes = await _confirmDelete(context, persona.label);
    if (!yes) return;
    await Personas.instance.forget(persona.id);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final kept = MessageHistory.instance.enabled;
    final personas = Personas.instance.all;

    return SettingsDialog(
      title: 'Profiles',
      subtitle: kept
          ? 'Kept on this machine, with your message history.'
          : 'Kept until ddIRC closes. Turn on message history to keep them.',
      children: [
        const SettingsProse(
          'A profile is a name for your own reference — a network never sees '
          'it. Point a network at one and ddIRC connects under a random nick '
          'it keeps just for that server, so the same you on two networks '
          'looks like two different people.',
          padding: EdgeInsets.fromLTRB(18, 4, 18, 12),
        ),
        SettingsSection(
          label: 'New profile',
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: SettingsField(
                      controller: _new,
                      hint: 'Work, Anonymous, …',
                      onSubmitted: (_) => _create(),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SettingsSecondaryButton(
                    label: 'Add',
                    tone: context.tokens.accent,
                    onPressed: _create,
                  ),
                ],
              ),
            ),
          ],
        ),
        if (personas.isNotEmpty)
          SettingsSection(
            label: 'Your profiles',
            children: [
              for (final persona in personas)
                _PersonaRow(
                  persona: persona,
                  nicks: Personas.instance.nicksOf(persona.id),
                  onRename: () => _rename(persona),
                  onDelete: () => _delete(persona),
                ),
            ],
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _PersonaRow extends StatelessWidget {
  const _PersonaRow({
    required this.persona,
    required this.nicks,
    required this.onRename,
    required this.onDelete,
  });

  final Persona persona;

  /// networkId → the nick this profile wears there. Only the count is shown,
  /// with the nicks themselves on hover: which server is which is the app's
  /// business, and a wall of random handles is not something to read.
  final Map<String, String> nicks;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final count = nicks.length;
    final subtitle = count == 0
        ? 'Not used on any network yet'
        : count == 1
        ? 'One network'
        : '$count networks';

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 10, 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  persona.label,
                  style: TextStyle(color: t.text, fontSize: 14),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Tooltip(
                  message: nicks.isEmpty ? '' : nicks.values.join(', '),
                  child: Text(
                    subtitle,
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                ),
              ],
            ),
          ),
          _IconAction(
            icon: Icons.edit_outlined,
            tooltip: 'Rename',
            onTap: onRename,
          ),
          _IconAction(
            icon: Icons.delete_outline,
            tooltip: 'Delete',
            onTap: onDelete,
            danger: true,
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: Touchable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        builder: (context, touch) => Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: t.surfaceHover.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 16, color: danger ? t.bad : t.muted),
        ),
      ),
    );
  }
}

/// Ask for a profile name in a small prompt. Returns the trimmed name, or
/// null if cancelled.
///
/// The dialog owns its controller and disposes it in [State.dispose] — the one
/// time it is safe to. Disposing on the returned future instead (the obvious
/// shortcut) fires the moment the pop is *requested*, while the exit animation
/// is still rebuilding the field, and the field then touches a controller that
/// is already gone.
Future<String?> askPersonaName(
  BuildContext context, {
  required String title,
  String saveLabel = 'Save',
  String? hint,
  String initial = '',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _NamePrompt(
      title: title,
      saveLabel: saveLabel,
      hint: hint,
      initial: initial,
    ),
  );
}

class _NamePrompt extends StatefulWidget {
  const _NamePrompt({
    required this.title,
    required this.saveLabel,
    required this.hint,
    required this.initial,
  });

  final String title;
  final String saveLabel;
  final String? hint;
  final String initial;

  @override
  State<_NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<_NamePrompt> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return AlertDialog(
      backgroundColor: t.surface,
      title: Text(widget.title, style: TextStyle(color: t.text, fontSize: 16)),
      content: SettingsField(
        controller: _controller,
        hint: widget.hint,
        onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
      ),
      actions: [
        SettingsTertiaryButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
        SettingsPrimaryButton(
          label: widget.saveLabel,
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
        ),
      ],
    );
  }
}

Future<bool> _confirmDelete(BuildContext context, String label) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) {
      final t = context.tokens;
      return AlertDialog(
        backgroundColor: t.surface,
        title: Text(
          'Delete $label?',
          style: TextStyle(color: t.text, fontSize: 16),
        ),
        content: Text(
          'The random nicks this profile wears on your networks are '
          'forgotten with it. Any network still set to use it falls back to '
          'the nickname typed on the network itself.',
          style: TextStyle(color: t.muted, fontSize: 13, height: 1.4),
        ),
        actions: [
          SettingsTertiaryButton(
            label: 'Keep',
            onPressed: () => Navigator.of(context).pop(false),
          ),
          SettingsDangerButton(
            label: 'Delete',
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    },
  );
  return answer ?? false;
}
