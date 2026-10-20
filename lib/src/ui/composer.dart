import 'package:flutter/material.dart';

import '../theme.dart';
import 'layout.dart';
import 'motion.dart';
import 'text_direction.dart';

/// The place a message is typed, at the foot of a conversation.
///
/// It was an outlined text field with two loose buttons beside it, which is the
/// shape of a *form*: a box with a border that lights up, and controls parked
/// next to it as if they belonged to something else. A messenger's composer is
/// one object instead — a single soft surface the text and the paperclip live
/// inside, and one round button that is the only thing outside it — and that is
/// what this is. Nothing here has an outline, because the fill is the shape.
///
/// The send button is always there. It is quiet while there is nothing to send
/// and fills with the accent once there is, rather than appearing and
/// disappearing: a button that comes and goes changes the width of the field
/// next to it, so the first letter typed would reflow the text it belongs to.
///
/// The bar has no background of its own and no rule above it. The conversation
/// runs down to the composer, and the composer sits on it the way a bubble sits
/// in a conversation — which is also why it takes the bubble's colour.
class Composer extends StatelessWidget {
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSubmit,
    this.onAttach,
  });

  final TextEditingController controller;
  final FocusNode focusNode;

  /// What the empty field says: where a message typed now would go.
  final String hint;

  final VoidCallback onSubmit;

  /// The paperclip, when there is somewhere to send a file. Left out entirely
  /// otherwise: a button that opens a picker and then explains that the feature
  /// is off is a button that wasted the user's time.
  final VoidCallback? onAttach;

  /// The height of one line of text with its padding: the bar's minimum, and
  /// the size of the send button, so the two sit level with each other.
  static const _height = 44.0;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    final attach = onAttach;

    return Padding(
      padding: EdgeInsets.fromLTRB(g - 4, 6, g - 4, 8),
      child: Row(
        // Bottom-aligned, so when the field grows to several lines the buttons
        // stay beside the line being typed rather than floating mid-way up.
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.bubble,
                borderRadius: BorderRadius.circular(_height / 2),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    // Rebuilt as the text changes, because the direction is a
                    // property of what has been typed: the first Persian
                    // letter turns the field right to left, the way every
                    // messenger's does, and clearing it turns it back. Until
                    // there is a letter with a direction it stays as it was,
                    // so the placeholder does not jump about.
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => TextField(
                        controller: controller,
                        focusNode: focusNode,
                        textDirection: strongDirectionOf(controller.text),
                        onSubmitted: (_) => onSubmit(),
                        textInputAction: TextInputAction.send,
                        maxLines: 5,
                        minLines: 1,
                        autocorrect: false,
                        cursorColor: t.accent,
                        style: TextStyle(color: t.text, fontSize: 15),
                        decoration: InputDecoration(
                          hintText: hint,
                          hintStyle: TextStyle(color: t.faint, fontSize: 15),
                          isDense: true,
                          // Every border named, because the app's input theme
                          // supplies one for each state and an unnamed state
                          // falls back to it.
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          contentPadding: EdgeInsets.fromLTRB(
                            18,
                            (_height - 20) / 2,
                            attach == null ? 18 : 4,
                            (_height - 20) / 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (attach != null)
                    IconButton(
                      onPressed: attach,
                      icon: const Icon(Icons.attach_file, size: 22),
                      color: t.muted,
                      tooltip: 'Send a file',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                        width: _height,
                        height: _height,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          _SendButton(controller: controller, onSubmit: onSubmit),
        ],
      ),
    );
  }
}

/// The round button beside the field: quiet when there is nothing to send,
/// the accent when there is.
///
/// Listens to the controller itself, so a keystroke rebuilds this button and
/// nothing else. The conversation screen around it is large, and on a slow
/// phone rebuilding it per character is the difference between a composer that
/// keeps up and one that lags behind the typing.
class _SendButton extends StatelessWidget {
  const _SendButton({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final motion = context.motion;

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final ready = value.text.trim().isNotEmpty;
        return SizedBox.square(
          dimension: Composer._height,
          child: AnimatedSwitcher(
            duration: motion.normal,
            switchInCurve: Motion.curve,
            switchOutCurve: Motion.exit,
            transitionBuilder: Motion.scaleFade,
            child: IconButton.filled(
              // Keyed on the state, so the switcher sees two different
              // widgets and animates between them rather than repainting one.
              key: ValueKey(ready),
              onPressed: ready ? onSubmit : null,
              icon: const Icon(Icons.arrow_upward_rounded, size: 22),
              tooltip: 'Send',
              style: IconButton.styleFrom(
                fixedSize: const Size.square(Composer._height),
                backgroundColor: t.accent,
                foregroundColor: t.onAccent,
                disabledBackgroundColor: t.bubble,
                disabledForegroundColor: t.faint,
              ),
            ),
          ),
        );
      },
    );
  }
}
