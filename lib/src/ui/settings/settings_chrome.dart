import 'package:flutter/material.dart';

import '../../theme.dart';
import '../motion.dart';
import '../shake.dart';
import '../touchable.dart';

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
    this.onBack,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final double width;

  /// Shows a back arrow to the left of the title, for a dialog that is one
  /// level down inside itself.
  ///
  /// The close button stays where it is. Back and close answer different
  /// questions — *up one level* and *I am finished* — and a dialog two levels
  /// deep that could only be left by retracing its own steps would be worse
  /// than the flat list it replaced.
  final VoidCallback? onBack;

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
      // The back arrow brings its own leading inset, so the title sits on the
      // same vertical line either way.
      padding: EdgeInsets.fromLTRB(onBack == null ? 18 : 6, 15, 8, 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (onBack != null) ...[
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back, size: 18),
              color: t.muted,
              visualDensity: VisualDensity.compact,
              tooltip: 'Back to settings',
            ),
            const SizedBox(width: 2),
          ],
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

/// A labelled group of rows, and the unit a settings page is built from.
class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.label,
    required this.children,
    this.beta = false,
  });

  final String label;
  final List<Widget> children;

  /// Puts a [BetaBadge] beside the heading.
  ///
  /// On the section rather than on the switch inside it, because what is beta
  /// is the whole feature — the readouts below the switch are as provisional
  /// as the switch is.
  final bool beta;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Row(
            children: [
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  color: t.faint,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.9,
                ),
              ),
              if (beta) ...[const SizedBox(width: 7), const BetaBadge()],
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// Says a feature is not finished, wherever that feature is offered.
///
/// One widget rather than the word written into each label, because there is
/// more than one beta feature and two of them drifting apart — different
/// wording, different colour, one of them quietly dropped in a refactor —
/// would leave the user unable to tell which warnings still stand.
///
/// The colour is the warning one, not the accent. A badge in the accent
/// colour reads as a feature being advertised, and this is the opposite of
/// that: it is the app declining to promise something.
class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key, this.tooltip = _default});

  static const _default =
      'Beta: this works, but it is new, it will have gaps, and it may '
      'change. Do not depend on it for anything that matters.';

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        decoration: BoxDecoration(
          color: t.warn.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          'BETA',
          style: TextStyle(
            color: t.warn,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      ),
    );
  }
}

/// A row that opens a page of settings rather than changing one.
///
/// The index of the settings dialog is made of these. Each carries a summary
/// of what is currently set inside it, and that is not decoration: a flat list
/// showed the whole state at a glance, and a menu that hides it behind three
/// taps is a straight loss unless each row says what it is holding. So the
/// Connection row reads "Built-in Tor" when Tor is on, and someone checking
/// whether they are proxied never has to open anything.
class SettingsNavRow extends StatelessWidget {
  const SettingsNavRow({
    super.key,
    required this.label,
    required this.summary,
    required this.onTap,
    this.beta = false,
  });

  final String label;

  /// What is set inside, in a handful of words. Never empty — a row with
  /// nothing to report says what it governs instead.
  final String summary;

  final VoidCallback onTap;

  /// Marks a page that contains a beta feature. On the row as well as inside,
  /// because the point of the badge is to be seen before the thing is reached.
  final bool beta;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Touchable(
      onTap: onTap,
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        color: t.surfaceHover.withValues(alpha: touch.wash),
        padding: const EdgeInsets.fromLTRB(18, 13, 12, 13),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (beta) ...[
                        const SizedBox(width: 8),
                        const BetaBadge(),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    summary,
                    style: TextStyle(
                      color: t.muted,
                      fontSize: 12,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_right, size: 18, color: t.faint),
          ],
        ),
      ),
    );
  }
}

/// A group of rows behind one heading that can be folded away.
///
/// For the parts of a form most people never touch. Collapsed, the form is the
/// three or four answers a network actually needs; expanded, nothing has moved
/// anywhere else, which is the difference between this and a second dialog.
///
/// Deliberately controlled rather than holding its own [open] state. The
/// caller has to be able to open it without being asked — a validation error
/// inside something folded away is an error nobody can see, and a form that
/// refuses to save while showing nothing wrong is the worst version of this
/// pattern.
class SettingsDisclosure extends StatelessWidget {
  const SettingsDisclosure({
    super.key,
    required this.label,
    required this.summary,
    required this.children,
    required this.open,
    required this.onToggle,
  });

  final String label;

  /// Shown beside the heading while it is shut, so what is folded away is
  /// still named. This is what stops a disclosure hiding a setting the user
  /// has already changed.
  final String summary;

  final List<Widget> children;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Touchable(
          onTap: onToggle,
          builder: (context, touch) => AnimatedContainer(
            duration: context.motion.fast,
            curve: Motion.curve,
            color: t.surfaceHover.withValues(alpha: touch.wash),
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 12),
            child: Row(
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: t.text,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    open ? '' : summary,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.faint, fontSize: 11.5),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  duration: context.motion.normal,
                  curve: Motion.curve,
                  turns: open ? 0.25 : 0,
                  child: Icon(Icons.chevron_right, size: 18, color: t.faint),
                ),
              ],
            ),
          ),
        ),
        Reveal(
          child: open
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                )
              : null,
        ),
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
                fontFamily: monospace ? Fonts.mono : null,
                fontFamilyFallback: monospace ? Fonts.monoFallback : null,
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

/// An action that is neither the expected one nor a destructive one.
///
/// Exists for the case where both answers are ordinary and one of them merely
/// happens to be safer — a consent dialog, where "turn it on" is a legitimate
/// choice that should be findable without being urged.
class SettingsSecondaryButton extends StatelessWidget {
  const SettingsSecondaryButton({
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
        foregroundColor: t.text,
        side: BorderSide(color: t.rule, width: Tokens.hairline),
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
