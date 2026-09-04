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
class SettingsSection extends StatefulWidget {
  const SettingsSection({
    super.key,
    required this.label,
    required this.children,
    this.beta = false,
    this.help,
  });

  final String label;
  final List<Widget> children;

  /// Puts a [BetaBadge] beside the heading.
  ///
  /// On the section rather than on the switch inside it, because what is beta
  /// is the whole feature — the readouts below the switch are as provisional
  /// as the switch is.
  final bool beta;

  /// What the whole section is, behind a [HelpDot] on the heading.
  ///
  /// For the paragraph that explains the feature rather than any one control
  /// in it — the sort of thing that used to sit under the last readout as a
  /// [SettingsNote] and was read once, by everybody, forever.
  final String? help;

  @override
  State<SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<SettingsSection> {
  bool _help = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final help = widget.help;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // Tighter above when a dot is present: the dot is taller than the
          // heading it sits beside and would otherwise push every section
          // apart by the difference.
          padding: EdgeInsets.fromLTRB(18, help == null ? 14 : 8, 18, 6),
          child: Row(
            children: [
              Text(
                widget.label.toUpperCase(),
                style: TextStyle(
                  color: t.faint,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.9,
                ),
              ),
              if (widget.beta) ...[
                const SizedBox(width: 7),
                const BetaBadge(),
              ],
              if (help != null) ...[
                const SizedBox(width: 3),
                HelpDot(
                  open: _help,
                  subject: widget.label,
                  onToggle: () => setState(() => _help = !_help),
                ),
              ],
            ],
          ),
        ),
        HelpText(
          text: help,
          open: _help,
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
        ),
        ...widget.children,
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

/// The '?' that stands in for a paragraph.
///
/// Settings used to explain themselves in full underneath every control, and
/// the result was a dialog where the explanations outnumbered the switches
/// three lines to one. Nobody reads a wall of small grey text, and a page
/// where everything is explained at once is a page where nothing stands out —
/// including the two or three explanations that genuinely matter.
///
/// So the prose is still there, in full, and it is one tap away instead of
/// permanently in the way. Nothing is deleted and nothing is summarised: the
/// dot is a promise that pressing it gives back exactly what was there before.
///
/// Deliberately controlled rather than holding its own state, so the widget
/// that owns the row can put the '?' beside the label and the text below the
/// whole row — the two halves are never in the same place.
class HelpDot extends StatelessWidget {
  const HelpDot({
    super.key,
    required this.open,
    required this.onToggle,
    this.subject,
  });

  final bool open;
  final VoidCallback onToggle;

  /// What the help is about, for the tooltip. Without it the tooltip can only
  /// say "this", which is no use to someone reading with a screen reader and
  /// no pointer to say what "this" is next to.
  final String? subject;

  /// The dot occupies this square whether or not it is drawn, so a row of
  /// labels stays on one baseline when only some of them have help.
  static const size = 26.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final subject = this.subject;
    return Tooltip(
      message: open
          ? 'Hide the explanation'
          : subject == null
          ? 'What does this do?'
          : 'What does “$subject” do?',
      child: InkResponse(
        onTap: onToggle,
        radius: size / 2,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(
            child: AnimatedContainer(
              duration: context.motion.fast,
              curve: Motion.curve,
              width: 15,
              height: 15,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: open ? t.accent.withValues(alpha: 0.14) : null,
                border: Border.all(
                  color: open ? t.accent : t.rule,
                  width: Tokens.hairline,
                ),
              ),
              child: Text(
                '?',
                style: TextStyle(
                  color: open ? t.accent : t.faint,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  // Pinned, or the glyph's own leading pushes it off centre in
                  // a circle this small.
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The paragraph a [HelpDot] reveals.
///
/// Takes a nullable [text] so a caller with nothing to explain can drop this
/// in unconditionally rather than growing an `if` around it.
class HelpText extends StatelessWidget {
  const HelpText({
    super.key,
    required this.text,
    required this.open,
    this.padding = const EdgeInsets.only(top: 6, bottom: 2),
  });

  final String? text;
  final bool open;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final text = this.text;
    return Reveal(
      child: open && text != null
          ? Padding(
              padding: padding,
              child: Text(
                text,
                style: TextStyle(
                  color: t.faint,
                  fontSize: 11.5,
                  height: 1.45,
                ),
              ),
            )
          : null,
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
class SettingsSwitch extends StatefulWidget {
  const SettingsSwitch({
    super.key,
    required this.label,
    this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;

  /// What the switch means, behind a [HelpDot] rather than under the label.
  /// See [HelpDot] for why it is not simply printed.
  final String? description;

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  State<SettingsSwitch> createState() => _SettingsSwitchState();
}

class _SettingsSwitchState extends State<SettingsSwitch> {
  bool _help = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final description = widget.description;
    return InkWell(
      onTap: () => widget.onChanged(!widget.value),
      child: Padding(
        // Unchanged whether or not there is a dot: the switch is taller than
        // both the label and the dot, so it is the switch that sets this row's
        // height and adding help costs nothing until it is opened.
        padding: const EdgeInsets.fromLTRB(18, 9, 14, 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          widget.label,
                          style: TextStyle(color: t.text, fontSize: 13.5),
                        ),
                      ),
                      if (description != null)
                        // Inside the row's own InkWell, and that is safe: the
                        // innermost gesture recogniser takes the tap, so
                        // pressing the dot asks what the switch does instead
                        // of flipping it.
                        HelpDot(
                          open: _help,
                          subject: widget.label,
                          onToggle: () => setState(() => _help = !_help),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Switch(
                  value: widget.value,
                  onChanged: widget.onChanged,
                  activeThumbColor: t.onAccent,
                  activeTrackColor: t.accent,
                  inactiveThumbColor: t.muted,
                  inactiveTrackColor: t.surfaceHover,
                  trackOutlineColor: WidgetStatePropertyAll(t.rule),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
            // Full width under the switch rather than in a column beside it:
            // once it is opened deliberately it should be as readable as the
            // dialog can make it.
            HelpText(text: description, open: _help),
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
class SettingsChoice<T> extends StatefulWidget {
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

  /// What the choice means, behind a [HelpDot] rather than under the label.
  final String? description;

  final List<T> options;
  final String Function(T) labelFor;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  State<SettingsChoice<T>> createState() => _SettingsChoiceState<T>();
}

class _SettingsChoiceState<T> extends State<SettingsChoice<T>> {
  bool _help = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final description = widget.description;
    return Padding(
      padding: EdgeInsets.fromLTRB(18, description == null ? 9 : 5, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(color: t.text, fontSize: 13.5),
                ),
              ),
              if (description != null)
                HelpDot(
                  open: _help,
                  subject: widget.label,
                  onToggle: () => setState(() => _help = !_help),
                ),
            ],
          ),
          HelpText(text: description, open: _help),
          const SizedBox(height: 9),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: t.rule, width: Tokens.hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                for (final option in widget.options)
                  Expanded(
                    child: _Segment(
                      label: widget.labelFor(option),
                      selected: option == widget.value,
                      // A hairline between segments, never around the first.
                      leadingRule: option != widget.options.first,
                      onTap: () => widget.onChanged(option),
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
class SettingsField extends StatefulWidget {
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

  /// Hides what is typed, and puts an eye at the end of the field to show it
  /// again. See [_SettingsFieldState._reveal] for why the eye is not optional.
  final bool obscure;

  final String? error;

  /// Bumped by the caller to replay the shake on a repeated attempt.
  final int shakeTick;

  @override
  State<SettingsField> createState() => _SettingsFieldState();
}

class _SettingsFieldState extends State<SettingsField> {
  /// Whether the user has asked to see what they are typing.
  ///
  /// Every obscured field here takes a password that is typed once, cannot be
  /// checked anywhere else, and produces a failure hours later and on another
  /// screen if it is wrong — a SASL password that is one character out looks
  /// exactly like a server that is refusing the account. Dots alone are the
  /// wrong trade for that: the thing being hidden from is a person standing
  /// behind you, and they are not there most of the time.
  ///
  /// So it starts hidden, which is the right default, and it is one press to
  /// check. Never remembered: the field goes back to dots whenever the dialog
  /// is closed and reopened, because a reveal that outlives the moment it was
  /// wanted for is a password left on the screen.
  bool _reveal = false;

  @override
  void didUpdateWidget(SettingsField old) {
    super.didUpdateWidget(old);
    // A field that stops being a secret and later becomes one again must not
    // come back already showing.
    if (!widget.obscure && _reveal) _reveal = false;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final invalid = widget.error != null;
    final obscured = widget.obscure && !_reveal;

    return Shake(
      tick: invalid ? widget.shakeTick : 0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: widget.controller,
            // An obscured field is always single-line; passing minLines with
            // obscureText is an assertion failure in Flutter. It stays single
            // line while revealed too, so showing a password does not resize
            // the form around it.
            maxLines: widget.obscure ? 1 : widget.maxLines,
            minLines: widget.obscure ? null : 1,
            obscureText: obscured,
            enabled: widget.enabled,
            onSubmitted: widget.onSubmitted,
            autocorrect: false,
            enableSuggestions: false,
            style: TextStyle(
              color: widget.enabled ? t.text : t.muted,
              fontSize: 13.5,
              height: 1.35,
            ),
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: TextStyle(color: t.faint, fontSize: 13.5),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 11,
                vertical: 11,
              ),
              suffixIcon: widget.obscure && widget.enabled
                  ? _RevealButton(
                      revealed: _reveal,
                      onToggle: () => setState(() => _reveal = !_reveal),
                    )
                  : null,
              // Without this the eye claims Material's default 48-square and
              // the field grows taller than every other one in the form.
              suffixIconConstraints: const BoxConstraints(
                minWidth: 34,
                minHeight: 34,
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
                widget.error!,
                style: TextStyle(color: t.bad, fontSize: 11.5, height: 1.35),
              ),
            ),
        ],
      ),
    );
  }
}

/// The eye at the end of a secret field.
///
/// The icon shows the state the field is in rather than the state pressing it
/// would produce — an open eye means "this is visible" — and the tooltip says
/// what the press does. That pairing is the one people already know from
/// every other password field, and inventing a better one here would only
/// mean it has to be learned.
class _RevealButton extends StatelessWidget {
  const _RevealButton({required this.revealed, required this.onToggle});

  final bool revealed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: revealed ? 'Hide it again' : 'Show what is typed',
      child: InkResponse(
        onTap: onToggle,
        radius: 17,
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(
            revealed ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 17,
            color: revealed ? t.accent : t.faint,
          ),
        ),
      ),
    );
  }
}

/// A [SettingsField] with its own label above it, and optionally a [HelpDot]
/// beside the label.
///
/// One widget rather than the near-identical private helper the network editor
/// and the proxy form each had, because the two drifted the moment either one
/// grew anything — and what they grew was help, which has to sit in exactly
/// the same place in both or the '?' stops reading as one control.
class SettingsLabelledField extends StatefulWidget {
  const SettingsLabelledField({
    super.key,
    required this.label,
    required this.controller,
    this.help,
    this.hint,
    this.obscure = false,
    this.error,
    this.shakeTick = 0,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;

  /// What the field is for, and what happens to what is typed into it. Behind
  /// the '?': see [HelpDot].
  final String? help;

  final String? hint;
  final bool obscure;
  final String? error;
  final int shakeTick;
  final ValueChanged<String>? onSubmitted;

  @override
  State<SettingsLabelledField> createState() => _SettingsLabelledFieldState();
}

class _SettingsLabelledFieldState extends State<SettingsLabelledField> {
  bool _help = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final help = widget.help;
    final invalid = widget.error != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A fixed height, so two fields side by side start their boxes on
          // the same line whether or not either of them has a '?'.
          SizedBox(
            height: HelpDot.size,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    widget.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: invalid ? t.bad : t.muted,
                      fontSize: 12,
                    ),
                  ),
                ),
                if (help != null)
                  HelpDot(
                    open: _help,
                    subject: widget.label,
                    onToggle: () => setState(() => _help = !_help),
                  ),
              ],
            ),
          ),
          HelpText(
            text: help,
            open: _help,
            padding: const EdgeInsets.only(bottom: 6),
          ),
          const SizedBox(height: 3),
          SettingsField(
            controller: widget.controller,
            hint: widget.hint,
            obscure: widget.obscure,
            error: widget.error,
            shakeTick: widget.shakeTick,
            onSubmitted: widget.onSubmitted,
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
