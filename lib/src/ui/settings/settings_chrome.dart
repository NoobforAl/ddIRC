import 'package:flutter/material.dart';

import '../../theme.dart';
import '../shake.dart';

/// Shared chrome for the settings dialogs.
///
/// Modality is deliberate here and only here: settings are a detour the user
/// chose to take, so blocking the conversation until they are done is honest.
/// Connection state never uses a dialog — it stays inline, where it cannot
/// interrupt a sentence someone is typing.
class SettingsDialog extends StatelessWidget {
  const SettingsDialog({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
    this.width = 420,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final double width;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final viewport = MediaQuery.of(context).size;

    return Dialog(
      backgroundColor: t.surface,
      surfaceTintColor: Colors.transparent,
      // No elevation anywhere in this app; the hairline is the separation.
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: t.rule, width: Tokens.hairline),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: width,
          // Leave the dialog scrollable rather than clipped on a short window
          // or a phone in landscape.
          maxHeight: viewport.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 6),
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 15, 8, 14),
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
                  title,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.muted, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
            color: t.muted,
            visualDensity: VisualDensity.compact,
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}

/// A labelled group of rows.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.label,
    required this.children,
  });

  final String label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(
              color: t.faint,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.9,
            ),
          ),
        ),
        ...children,
      ],
    );
  }
}

/// One boolean preference.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 9, 14, 9),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: t.text, fontSize: 13.5)),
                  if (description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      description!,
                      style: TextStyle(
                        color: t.faint,
                        fontSize: 11.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: t.onAccent,
              activeTrackColor: t.accent,
              inactiveThumbColor: t.muted,
              inactiveTrackColor: t.surfaceHover,
              trackOutlineColor: WidgetStatePropertyAll(t.rule),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}

/// A small set of mutually exclusive options, shown in full.
///
/// A segmented row rather than a dropdown: with two or three choices, hiding
/// them behind a menu costs a tap and tells the user nothing.
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.label,
    this.description,
    required this.options,
    required this.labelFor,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String? description;
  final List<T> options;
  final String Function(T) labelFor;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 9, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: t.text, fontSize: 13.5)),
          if (description != null) ...[
            const SizedBox(height: 2),
            Text(
              description!,
              style: TextStyle(color: t.faint, fontSize: 11.5, height: 1.35),
            ),
          ],
          const SizedBox(height: 9),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: t.rule, width: Tokens.hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                for (final option in options)
                  Expanded(
                    child: _Segment(
                      label: labelFor(option),
                      selected: option == value,
                      // A hairline between segments, never around the first.
                      leadingRule: option != options.first,
                      onTap: () => onChanged(option),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.leadingRule,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool leadingRule;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          color: selected ? t.surfaceHover : null,
          border: Border(
            left: BorderSide(
              color: leadingRule ? t.rule : Colors.transparent,
              width: Tokens.hairline,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? t.accent : t.muted,
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

/// A fact the user can read but not change.
class SettingsReadout extends StatelessWidget {
  const SettingsReadout({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: TextStyle(color: t.muted, fontSize: 12.5),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: valueColor ?? t.text,
                fontSize: 12.5,
                height: 1.35,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single-line text field styled like the rest of the app.
///
/// When [error] is set the field itself turns red and shakes; nothing about
/// the problem is reported anywhere else, so there is only one place to look.
class SettingsField extends StatelessWidget {
  const SettingsField({
    super.key,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.onSubmitted,
    this.enabled = true,
    this.obscure = false,
    this.error,
    this.shakeTick = 0,
  });

  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final bool obscure;
  final String? error;

  /// Bumped by the caller to replay the shake on a repeated attempt.
  final int shakeTick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final invalid = error != null;

    return Shake(
      tick: invalid ? shakeTick : 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            // An obscured field is always single-line; passing minLines with
            // obscureText is an assertion failure in Flutter.
            maxLines: obscure ? 1 : maxLines,
            minLines: obscure ? null : 1,
            obscureText: obscure,
            enabled: enabled,
            onSubmitted: onSubmitted,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(
              color: enabled ? t.text : t.muted,
              fontSize: 13.5,
              height: 1.35,
            ),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(color: t.faint, fontSize: 13.5),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 11,
                vertical: 11,
              ),
              enabledBorder: outlinedBorder(
                invalid ? t.bad : t.rule,
                invalid ? 1 : Tokens.hairline,
              ),
              disabledBorder: outlinedBorder(t.rule, Tokens.hairline),
              focusedBorder: outlinedBorder(invalid ? t.bad : t.accent, 1),
            ),
          ),
          if (invalid)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                error!,
                style: TextStyle(color: t.bad, fontSize: 11.5, height: 1.35),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row of actions along the bottom of a section.
class SettingsActions extends StatelessWidget {
  const SettingsActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            children[i],
          ],
        ],
      ),
    );
  }
}

/// The primary action of a section.
class SettingsPrimaryButton extends StatelessWidget {
  const SettingsPrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: t.accent,
        foregroundColor: t.onAccent,
        disabledBackgroundColor: t.surfaceHover,
        disabledForegroundColor: t.faint,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

/// An action that removes something. Outlined, never filled — it should be
/// findable without competing with the thing the user probably came to do.
class SettingsDangerButton extends StatelessWidget {
  const SettingsDangerButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: t.bad,
        side: BorderSide(
          color: t.bad.withValues(alpha: 0.45),
          width: Tokens.hairline,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

/// Feedback for an action taken inside a dialog.
class SettingsNote extends StatelessWidget {
  const SettingsNote({super.key, required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = isError ? t.bad : t.muted;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 11.5, height: 1.4),
      ),
    );
  }
}

/// A hairline between sections.
class SettingsRule extends StatelessWidget {
  const SettingsRule({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 8),
      child: Divider(height: Tokens.hairline),
    );
  }
}
