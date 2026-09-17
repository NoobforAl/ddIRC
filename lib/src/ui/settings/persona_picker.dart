import 'package:flutter/material.dart';

import '../../model/history.dart';
import '../../model/personas.dart';
import '../../theme.dart';
import '../touchable.dart';
import 'personas_dialog.dart';
import 'settings_chrome.dart';

/// Chooses whether a network connects under a fixed nickname or one of the
/// user's identities, for the network editor's Identity section.
///
/// When an identity is picked the nick typed on the network is set aside for a
/// random one, generated once per network and kept — so the picker shows which
/// handle this network has, or will, wear rather than leaving the user to
/// guess what they will look like.
class PersonaPicker extends StatefulWidget {
  const PersonaPicker({
    super.key,
    required this.selected,
    required this.networkId,
    required this.onChanged,
    required this.fixedNickField,
  });

  /// The chosen identity's id, or null for a fixed nickname.
  final String? selected;

  /// The saved network this is for, so its remembered nick can be shown. Null
  /// while a network is still being added and has no id yet.
  final String? networkId;

  final ValueChanged<String?> onChanged;

  /// The nickname field to show when no identity is chosen.
  final Widget fixedNickField;

  @override
  State<PersonaPicker> createState() => _PersonaPickerState();
}

class _PersonaPickerState extends State<PersonaPicker> {
  @override
  void initState() {
    super.initState();
    Personas.instance.addListener(_onChanged);
  }

  @override
  void dispose() {
    Personas.instance.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _newProfile() async {
    final label = await askPersonaName(
      context,
      title: 'New profile',
      saveLabel: 'Create',
      hint: 'Work, Anonymous, …',
    );
    if (label == null || label.isEmpty) return;
    final id = await Personas.instance.create(label);
    widget.onChanged(id);
  }

  Future<void> _regenerate(String personaId) async {
    final networkId = widget.networkId;
    if (networkId == null) return;
    await Personas.instance.regenerate(personaId, networkId);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final kept = MessageHistory.instance.enabled;
    final personas = Personas.instance.all;

    // Profiles only make sense once there is somewhere to keep them: a random
    // nick that is forgotten at exit would be a new stranger every launch.
    if (!kept) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SettingsProse(
            'Turn on message history (in App settings) to connect under a '
            'profile — a random, per-network nick that stays yours across '
            'sessions. Until then a network uses the nickname below.',
            padding: EdgeInsets.fromLTRB(18, 4, 18, 10),
          ),
          widget.fixedNickField,
        ],
      );
    }

    final selected = widget.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Option(
          label: 'A fixed nickname',
          detail: 'Use the nickname you type below on this network.',
          selected: selected == null,
          onTap: () => widget.onChanged(null),
        ),
        for (final persona in personas)
          _Option(
            label: persona.label,
            detail: 'A random nick, kept just for this network.',
            selected: selected == persona.id,
            onTap: () => widget.onChanged(persona.id),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 4),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              SettingsSecondaryButton(
                label: 'New profile…',
                tone: t.accent,
                onPressed: _newProfile,
              ),
              SettingsSecondaryButton(
                label: 'Manage…',
                onPressed: () => PersonasDialog.show(context),
              ),
            ],
          ),
        ),
        // When a fixed nick is chosen the field appears; when an identity is,
        // the assigned handle takes its place so the two are never both asking
        // to be filled in.
        if (selected == null)
          widget.fixedNickField
        else
          _AssignedNick(
            personaId: selected,
            networkId: widget.networkId,
            onRegenerate: () => _regenerate(selected),
          ),
      ],
    );
  }
}

/// One radio-style choice: a title, a line of detail, a dot on the left.
class _Option extends StatelessWidget {
  const _Option({
    required this.label,
    required this.detail,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String detail;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Touchable(
      onTap: onTap,
      builder: (context, touch) => Container(
        color: t.surfaceHover.withValues(alpha: touch.wash),
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 16,
                color: selected ? t.accent : t.faint,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? t.text : t.muted,
                      fontSize: 13.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 1),
                  Text(
                    detail,
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

/// The handle a chosen identity wears here — or a note that one will be minted
/// on the first connection, when the network is too new to have one yet.
class _AssignedNick extends StatelessWidget {
  const _AssignedNick({
    required this.personaId,
    required this.networkId,
    required this.onRegenerate,
  });

  final String personaId;
  final String? networkId;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final nick = networkId == null
        ? null
        : Personas.instance.assignedNick(personaId, networkId!);

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Nick on this network',
                  style: TextStyle(color: t.faint, fontSize: 11.5),
                ),
                const SizedBox(height: 3),
                Text(
                  nick ?? 'Generated when you first connect',
                  style: TextStyle(
                    color: nick == null ? t.muted : t.text,
                    fontSize: 14,
                    fontFamily: nick == null ? null : Fonts.mono,
                    fontFamilyFallback: nick == null
                        ? null
                        : Fonts.monoFallback,
                    fontStyle: nick == null ? FontStyle.italic : null,
                  ),
                ),
              ],
            ),
          ),
          if (nick != null)
            SettingsSecondaryButton(
              label: 'Regenerate',
              onPressed: onRegenerate,
            ),
        ],
      ),
    );
  }
}
