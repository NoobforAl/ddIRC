import 'package:flutter/material.dart';

import '../model/session.dart';
import '../model/settings.dart';
import '../rust/api/types.dart' as rust;
import '../theme.dart';

/// The scrollback for one conversation.
class MessageView extends StatefulWidget {
  const MessageView({super.key, required this.conversation});

  final Conversation conversation;

  @override
  State<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends State<MessageView> {
  final _controller = ScrollController();

  /// Only auto-scroll when already at the bottom, so reading scrollback is not
  /// yanked away every time someone speaks.
  bool _pinnedToBottom = true;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      if (!_controller.hasClients) return;
      final position = _controller.position;
      _pinnedToBottom = position.pixels >= position.maxScrollExtent - 40;
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scrollIfPinned() {
    if (!_pinnedToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_controller.hasClients) {
        _controller.jumpTo(_controller.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final settings = SettingsScope.of(context);
    final all = widget.conversation.lines;
    // Filtering before grouping, not during: a hidden join between two of
    // someone's messages should let them group, not split the run.
    final lines = settings.showSystemMessages
        ? all
        : all.where((l) => l.kind != SystemKind.presence).toList();

    if (all.length != _lastCount) {
      _lastCount = all.length;
      _scrollIfPinned();
    }

    if (lines.isEmpty) {
      return const Center(
        child: Text(
          'Nothing here yet.',
          style: TextStyle(color: Tokens.faint, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      controller: _controller,
      padding: const EdgeInsets.symmetric(vertical: 10),
      itemCount: lines.length,
      itemBuilder: (context, i) {
        final line = lines[i];
        if (line.isSystem) return _SystemLine(text: line.system!);

        // Suppress the repeated sender label when the same person speaks
        // again within a couple of minutes — the run reads as one utterance
        // and the screen stays quieter.
        final previous = i > 0 ? lines[i - 1] : null;
        final grouped =
            previous != null &&
            !previous.isSystem &&
            previous.message!.sender == line.message!.sender &&
            previous.message!.isSelf == line.message!.isSelf &&
            line.at.difference(previous.at).inMinutes < 2;

        return _MessageLine(
          line: line,
          showSender: !grouped,
          settings: settings,
        );
      },
    );
  }
}

/// Joins, parts, topics, connection changes: smaller, muted, centred —
/// subordinate to real messages but never hidden.
class _SystemLine extends StatelessWidget {
  const _SystemLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Tokens.muted,
            fontSize: 11.5,
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

class _MessageLine extends StatelessWidget {
  const _MessageLine({
    required this.line,
    required this.showSender,
    required this.settings,
  });

  final ChatLine line;
  final bool showSender;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final message = line.message!;
    final mine = message.isSelf;

    return Container(
      width: double.infinity,
      // A wash, not a shout. The rule on the leading edge is what actually
      // catches the eye when scanning a long channel.
      decoration: line.isMention
          ? const BoxDecoration(
              color: Tokens.mention,
              border: Border(
                left: BorderSide(color: Tokens.mentionRule, width: 2),
              ),
            )
          : null,
      padding: EdgeInsets.fromLTRB(
        line.isMention ? 18 : 20,
        settings.density.verticalPadding,
        20,
        settings.density.verticalPadding,
      ),
      child: Column(
        // Own messages align opposite from everyone else's. No bubbles.
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (showSender)
            _SenderLabel(
              message: message,
              at: line.at,
              mine: mine,
              settings: settings,
            ),
          _MessageBody(
            message: message,
            mine: mine,
            renderColors: settings.renderColors,
          ),
        ],
      ),
    );
  }
}

class _SenderLabel extends StatelessWidget {
  const _SenderLabel({
    required this.message,
    required this.at,
    required this.mine,
    required this.settings,
  });

  final rust.ChatMessage message;
  final DateTime at;
  final bool mine;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    // Privilege is plain text, straight from the server's ISUPPORT — never a
    // badge, and never a hardcoded @/+ that would break on networks with
    // halfop or owner prefixes.
    final prefix = message.senderPrefix ?? '';
    final time = settings.showTimestamps
        ? Text(
            settings.formatTime(at),
            style: const TextStyle(
              color: Tokens.faint,
              fontSize: 10.5,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          )
        : null;
    final nick = Text(
      '$prefix${message.sender}',
      style: TextStyle(
        color: mine ? Tokens.accent : Tokens.muted,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
      ),
    );

    return Padding(
      padding: EdgeInsets.only(
        top: settings.density == Density.compact ? 3 : 5,
        bottom: 1,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: time == null
            ? [nick]
            : mine
            ? [time, const SizedBox(width: 7), nick]
            : [nick, const SizedBox(width: 7), time],
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({
    required this.message,
    required this.mine,
    required this.renderColors,
  });

  final rust.ChatMessage message;
  final bool mine;

  /// When false, bold and italics still apply but sender-chosen colours are
  /// dropped — the styling that carries meaning is kept, the decoration is not.
  final bool renderColors;

  @override
  Widget build(BuildContext context) {
    const base = TextStyle(color: Tokens.text, fontSize: 14, height: 1.4);

    // Actions read in the third person; notices are services rather than
    // people, and the classic -nick- form is worth keeping so they are
    // instantly distinguishable.
    final leading = message.isAction
        ? '• '
        : message.isNotice
        ? '-${message.sender}- '
        : '';

    final style = message.isAction
        ? base.copyWith(fontStyle: FontStyle.italic, color: Tokens.text)
        : message.isNotice
        ? base.copyWith(color: Tokens.muted)
        : base;

    return RichText(
      textAlign: mine ? TextAlign.right : TextAlign.left,
      text: TextSpan(
        style: style,
        children: [
          if (leading.isNotEmpty)
            TextSpan(
              text: leading,
              style: style.copyWith(color: Tokens.faint),
            ),
          ...message.spans.map((span) => _span(span, style, renderColors)),
        ],
      ),
    );
  }

  /// Map one sanitised run from the core onto a Flutter span.
  ///
  /// The text is already free of control characters, so nothing here needs to
  /// re-sanitise; only the styling flags matter.
  static TextSpan _span(rust.TextSpan span, TextStyle base, bool colors) {
    final s = span.style;
    final background = colors ? MircPalette.background(s.bg) : null;
    // Contrast is measured against whatever this run actually sits on, so a
    // server-chosen foreground can never vanish into its own background.
    final surface = background ?? Tokens.bg;

    var style = base.copyWith(
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      fontFamily: s.monospace ? 'monospace' : null,
      color: (!colors || s.fg == null)
          ? base.color
          : MircPalette.resolve(s.fg, on: surface, fallback: base.color!),
      backgroundColor: background,
      decoration: TextDecoration.combine([
        if (s.underline) TextDecoration.underline,
        if (s.strikethrough) TextDecoration.lineThrough,
      ]),
      decorationColor: base.color,
    );

    // Reverse video: swap foreground and background rather than ignoring it,
    // since it is sometimes the only styling a message carries.
    if (s.inverse) {
      style = style.copyWith(
        color: background ?? Tokens.bg,
        backgroundColor: style.color ?? Tokens.text,
      );
    }

    return TextSpan(text: span.text, style: style);
  }
}
