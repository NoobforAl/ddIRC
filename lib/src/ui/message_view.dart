import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;

import '../model/people.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../rust/api/types.dart' as rust;
import '../theme.dart';
import 'avatar.dart';
import 'count_badge.dart';
import 'layout.dart';
import 'motion.dart';
import 'nick_color.dart';
import 'touchable.dart';

/// The scrollback for one conversation.
class MessageView extends StatefulWidget {
  const MessageView({
    super.key,
    required this.conversation,
    this.profileId,
    this.onPersonTap,
  });

  final Conversation conversation;

  /// Which network this is, for what the user has written about the people
  /// on it. Null draws everyone as the server names them.
  final String? profileId;

  /// A name in the scrollback was tapped.
  final ValueChanged<String>? onPersonTap;

  @override
  State<MessageView> createState() => _MessageViewState();
}

class _MessageViewState extends State<MessageView> {
  final _controller = ScrollController();

  /// Where the rows find out about each other, so a copy that spans several
  /// of them comes out as several lines. See [_ScrollbackSelection].
  final _selection = _ScrollbackSelection();

  /// The sliver the viewport is anchored on when the scrollback opens at the
  /// first unread line rather than at the bottom. See [_split].
  static const _centerKey = ValueKey('unread');

  /// Where reading should start, copied once from the conversation when this
  /// view is created and never re-read.
  ///
  /// Once, because the view's lifetime *is* the visit: it is keyed on the
  /// conversation and rebuilt when the user moves to another one. The model
  /// clears its own marker on leaving — while this view is still fading out
  /// — and the rule has to stay where it is until then, not vanish the moment
  /// the model forgets it.
  ChatLine? _marker;

  /// Whether the list is laid out in two halves around [_marker].
  ///
  /// A scrollback that opens on an unread line cannot be a list that opens at
  /// the top and jumps: the rows above the line are not built until they are
  /// scrolled to, so there is nothing to measure a jump against. Instead the
  /// viewport is *centred* on the marker's row — Flutter lays that sliver at
  /// offset zero and grows the older rows upward from it — which puts the rule
  /// at the top of the screen in one pass, whatever the rows above it turn
  /// out to measure.
  ///
  /// Only worth it when the unread tail is taller than the viewport. When it
  /// is not, opening at the marker would leave blank space under the last
  /// line, so [_probe] switches back to the plain, bottom-anchored list and
  /// the rule sits a few rows up from the bottom instead.
  bool _split = false;
  bool _decided = false;

  /// Only auto-scroll when already at the bottom, so reading scrollback is not
  /// yanked away every time someone speaks.
  bool _pinnedToBottom = true;

  /// How many settling jumps are in flight. See [_settleAtBottom].
  int _settling = 0;

  /// The last line seen by the previous build, so arrivals can be counted.
  /// The line rather than the count: at the cap the count stops changing.
  ChatLine? _lastLine;

  /// Whether the reader is away from the bottom, and how many messages have
  /// landed there since. Notifiers rather than state so the button in the
  /// corner can follow them without the whole scrollback rebuilding.
  final _away = ValueNotifier<bool>(false);
  final _arrived = ValueNotifier<int>(0);

  /// Which rows are new enough to animate in, and under what filter that was
  /// decided. Two conditions have to agree before a line fades in: it has to
  /// sit past the end of what was on screen last build, *and* it has to have
  /// happened just now. Either alone gets it wrong — the index alone replays
  /// the tail every time it is scrolled back to, and the timestamp alone makes
  /// a channel joined mid-conversation flash its whole backlog at once.
  static const _arrival = Duration(seconds: 1);
  int _seen = -1;
  bool _showedSystem = true;
  int _freshFrom = 0;

  @override
  void initState() {
    super.initState();
    _marker = widget.conversation.unreadMarker;
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.dispose();
    _away.dispose();
    _arrived.dispose();
    super.dispose();
  }

  void _onScroll() {
    // A jump that landed short of a bottom still being measured is not the
    // user scrolling up, and must not be read as one.
    if (!_controller.hasClients || _settling > 0) return;
    final position = _controller.position;
    final pinned = position.pixels >= position.maxScrollExtent - 40;
    _pinnedToBottom = pinned;
    _away.value = !pinned;
    // Reaching the bottom is reading what was there.
    if (pinned) _arrived.value = 0;
  }

  void _scrollIfPinned() {
    if (!_pinnedToBottom) return;
    _settleAtBottom();
  }

  /// Go to the bottom, and keep going until the bottom stops moving.
  ///
  /// `maxScrollExtent` is an estimate while rows below the viewport are
  /// unbuilt â€” the list extrapolates from the ones it has â€” and a single jump
  /// to it lands wherever the guess was, with the real last line still below.
  /// Each jump builds more rows and revises the guess, so the jump is repeated
  /// across frames until pixels and extent agree. Bounded, because a list
  /// that grows on every frame would otherwise keep this running forever.
  void _settleAtBottom({int attempt = 0}) {
    _settling++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _settling--;
      if (!mounted || !_controller.hasClients) return;
      final position = _controller.position;
      if (position.pixels < position.maxScrollExtent - 0.5 && attempt < 8) {
        _controller.jumpTo(position.maxScrollExtent);
        _settleAtBottom(attempt: attempt + 1);
        return;
      }
      _pinnedToBottom = true;
      _away.value = false;
      _arrived.value = 0;
    });
  }

  /// After the split layout: does the unread tail fill the viewport?
  ///
  /// Anchored at the marker, the scrollable range below it is however much of
  /// the tail does not fit. Zero means all of it did, and the rule belongs a
  /// few rows above the bottom rather than at the top with a gap beneath.
  ///
  /// Answered only once the viewport has held one height for two frames. The
  /// bars around the scrollback unroll over a quarter of a second, and a
  /// frame mid-unroll answers for a viewport that will not exist by the next
  /// one — a taller one, typically, into which a tail fits that will not fit
  /// once the bar has finished arriving. Bounded, so a window being resized
  /// by hand still gets an answer eventually.
  void _probe({int frames = 0, double? seen}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients || !_split) return;
      final position = _controller.position;
      final height = position.viewportDimension;
      if (height != seen && frames < 40) {
        _probe(frames: frames + 1, seen: height);
        return;
      }
      if (position.maxScrollExtent > 0) return;
      setState(() {
        _split = false;
        _pinnedToBottom = true;
      });
      _away.value = false;
      _arrived.value = 0;
      _scrollIfPinned();
    });
  }

  Future<void> _jumpToLatest() async {
    if (!_controller.hasClients) return;
    await _controller.animateTo(
      _controller.position.maxScrollExtent,
      duration: context.motion.slow,
      curve: Motion.curve,
    );
    if (!mounted) return;
    // The extent was an estimate until the rows on the way down were built;
    // the animation may have stopped short of where the bottom turned out to
    // be, and a jump-to-latest that stops short is not one.
    _settleAtBottom();
  }

  /// Messages, not noise: a join between two unread lines is not something
  /// the badge should count.
  static int _spoken(List<ChatLine> lines, int from) {
    var n = 0;
    for (var i = from; i < lines.length; i++) {
      if (!lines[i].isSystem) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final settings = SettingsScope.of(context);
    final all = widget.conversation.lines;
    // Filtering before grouping, not during: a hidden join between two of
    // someone's messages should let them group, not split the run.
    final lines = settings.showSystemMessages
        ? all
        : all.where((l) => l.kind != SystemKind.presence).toList();

    // The marker's place in what is on screen. Identity, not equality — a
    // line is only ever itself. Found again every build because the cap and
    // restored history both move indices under it.
    var markerIndex = _marker == null ? -1 : lines.indexOf(_marker!);
    if (!_decided) {
      _decided = true;
      if (markerIndex > 0) {
        _split = true;
        _pinnedToBottom = false;
        _away.value = true;
        _arrived.value = _spoken(lines, markerIndex);
        _probe();
      } else {
        // Nothing unread, or everything is: either way there is nowhere to
        // open but the bottom, and no rule to draw.
        _marker = null;
        markerIndex = -1;
      }
    } else if (_marker != null && markerIndex == -1) {
      // Trimmed off the top while being read. Everything left is unread, so
      // the rule above the first line is still the truth.
      markerIndex = 0;
    }

    final last = all.isEmpty ? null : all.last;
    if (!identical(last, _lastLine)) {
      var arrived = 0;
      var spoke = false;
      if (_lastLine != null) {
        for (var i = all.length - 1; i >= 0; i--) {
          if (identical(all[i], _lastLine)) break;
          if (all[i].isSystem) continue;
          arrived++;
          if (all[i].isSelf) spoke = true;
        }
      }
      _lastLine = last;
      // Saying something is a decision to be at the bottom: the reply will
      // land there, and nobody sends a message in order to go on reading
      // last week's. The one arrival that is allowed to move the page.
      if (spoke) {
        _pinnedToBottom = true;
        _arrived.value = 0;
      } else if (arrived > 0 && !_pinnedToBottom) {
        _arrived.value += arrived;
      }
      _scrollIfPinned();
    }

    if (_seen < 0 || settings.showSystemMessages != _showedSystem) {
      // First build, or the filter just moved every index: nothing here
      // arrived, it was already here.
      _freshFrom = lines.length;
    } else if (lines.length > _seen) {
      _freshFrom = _seen;
    }
    _seen = lines.length;
    _showedSystem = settings.showSystemMessages;

    if (lines.isEmpty) {
      return Center(
        child: Text(
          'Nothing here yet.',
          style: TextStyle(color: t.faint, fontSize: 13),
        ),
      );
    }

    // Once per build rather than once per row. `DateTime.now()` is a syscall
    // on every platform, and asking it the same question fifteen times inside
    // one frame cannot get fifteen different answers worth having.
    final now = DateTime.now();
    final arrivedAfter = now.subtract(_arrival);

    Widget row(int i) => _row(
      i,
      lines: lines,
      markerIndex: markerIndex,
      arrivedAfter: arrivedAfter,
      now: now,
      settings: settings,
    );

    final split = _split && markerIndex > 0;
    final slivers = split
        ? [
            // Older rows grow upward from the anchor, so their indices run
            // backwards and the padding that reads as `top` lands at the far
            // end — above the oldest line, where it belongs.
            SliverPadding(
              padding: const EdgeInsets.only(top: 10),
              sliver: SliverList.builder(
                itemCount: markerIndex,
                itemBuilder: (context, i) => row(markerIndex - 1 - i),
              ),
            ),
            SliverPadding(
              key: _centerKey,
              padding: const EdgeInsets.only(bottom: 10),
              sliver: SliverList.builder(
                itemCount: lines.length - markerIndex,
                itemBuilder: (context, i) => row(markerIndex + i),
              ),
            ),
          ]
        : [
            SliverPadding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              sliver: SliverList.builder(
                itemCount: lines.length,
                itemBuilder: (context, i) => row(i),
              ),
            ),
          ];

    // Selection lives out here, around the whole list, because a selection
    // that stopped at one message would not be a selection anyone wanted:
    // quoting a conversation means taking the three lines it took to have it.
    // What is *excluded* is the metadata — see [_MessageLine] — so dragging
    // across a run of messages copies what was said and not a column of nicks
    // and clock times interleaved through it.
    //
    // The button is outside the selection for the same reason: its count is
    // the app talking, not anyone in the channel.
    return Stack(
      children: [
        Positioned.fill(
          child: SelectionArea(
            child: CustomScrollView(
              controller: _controller,
              center: split ? _centerKey : null,
              anchor: 0,
              slivers: slivers,
            ),
          ),
        ),
        Positioned(
          right: context.layout.gutter,
          bottom: 12,
          child: ValueListenableBuilder<bool>(
            valueListenable: _away,
            builder: (context, away, _) => Appear(
              child: away
                  ? ValueListenableBuilder<int>(
                      // Keyed on presence, not on the count, so a message
                      // landing below does not re-scale the button.
                      key: const ValueKey('jump'),
                      valueListenable: _arrived,
                      builder: (context, count, _) =>
                          _JumpToLatest(count: count, onTap: _jumpToLatest),
                    )
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(
    int i, {
    required List<ChatLine> lines,
    required int markerIndex,
    required DateTime arrivedAfter,
    required DateTime now,
    required AppSettings settings,
  }) {
    final line = lines[i];
    final fresh = i >= _freshFrom && line.at.isAfter(arrivedAfter);
    final previous = i > 0 ? lines[i - 1] : null;
    final newDay =
        previous == null || !AppSettings.sameDay(previous.at, line.at);
    final unreadStart = i == markerIndex;

    Widget body;
    if (line.isSystem) {
      body = _SystemLine(text: line.system!);
    } else {
      // Suppress the repeated sender label when the same person speaks again
      // within a couple of minutes — the run reads as one utterance and the
      // screen stays quieter. Never across a rule, though: the first unread
      // line is where reading starts, and it should say who is talking.
      final grouped =
          !unreadStart &&
          // A new day implies a previous line, which is why the analyzer
          // lets `previous` through unchecked below.
          !newDay &&
          !previous.isSystem &&
          previous.message!.sender == line.message!.sender &&
          previous.message!.isSelf == line.message!.isSelf &&
          line.at.difference(previous.at).inMinutes < 2;
      body = _MessageLine(
        line: line,
        showSender: !grouped,
        settings: settings,
        card: widget.profileId == null
            ? null
            : People.instance.of(widget.profileId!, line.message!.sender),
        onPersonTap: widget.onPersonTap,
      );
    }

    // Rules ride inside the row they precede rather than being rows of their
    // own, so every index here is still an index into [lines].
    if (newDay || unreadStart) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (newDay) _Rule(label: AppSettings.describeDay(line.at, now: now)),
          if (unreadStart) const _Rule(label: 'New messages', loud: true),
          body,
        ],
      );
    }

    return _SelectableLine(
      index: i,
      scrollback: _selection,
      child: Arrive(play: fresh, child: body),
    );
  }
}

/// Where a copied selection gets its line breaks.
///
/// Flutter writes every selected paragraph into one buffer with nothing in
/// between, so three messages come back as one run-on string. The obvious fix —
/// one selection container around the whole list, joining its children — does
/// not work: [Scrollable] already puts a container of its own around the
/// viewport for auto-scrolling, and that one does the concatenating before
/// anything outside the list ever sees it. So the join has to happen *inside*,
/// one row at a time, and a row that cannot see its neighbours needs this to
/// tell it whether anything above it is also selected.
///
/// The separator goes in front of a continuing row rather than after every
/// row. Appending would be simpler and would put a line break on the end of
/// every copy, including a few words dragged out of the middle of a single
/// message — which is not something the user selected.
class _ScrollbackSelection {
  final _rows = <_LineSelection>{};

  void register(_LineSelection row) => _rows.add(row);
  void unregister(_LineSelection row) => _rows.remove(row);

  /// Whether [row] continues a selection that began further up.
  ///
  /// Rows are compared by their place in the scrollback rather than by the
  /// order they registered in, because scrolling registers them in whichever
  /// direction the list was scrolled.
  bool continues(_LineSelection row) =>
      _rows.any((other) => other.index < row.index && other.value.hasSelection);
}

/// One row's share of the selection, and the line break in front of it.
class _LineSelection extends StaticSelectionContainerDelegate {
  _LineSelection(this.scrollback, this.index);

  final _ScrollbackSelection scrollback;

  /// This row's position in the scrollback. Reassigned as the list scrolls —
  /// rows are recycled, so the delegate outlives any one index.
  int index;

  @override
  SelectedContent? getSelectedContent() {
    final content = super.getSelectedContent();
    if (content == null) return null;
    return scrollback.continues(this)
        ? SelectedContent(plainText: '\n${content.plainText}')
        : content;
  }
}

/// Wraps one row in its own selection container.
///
/// Stateful only because the delegate has to outlive the build: a
/// [SelectionContainer] registers and unregisters whatever it is handed, and a
/// fresh one every frame would drop the selection mid-drag.
class _SelectableLine extends StatefulWidget {
  const _SelectableLine({
    required this.index,
    required this.scrollback,
    required this.child,
  });

  final int index;
  final _ScrollbackSelection scrollback;
  final Widget child;

  @override
  State<_SelectableLine> createState() => _SelectableLineState();
}

class _SelectableLineState extends State<_SelectableLine> {
  late final _LineSelection _delegate = _LineSelection(
    widget.scrollback,
    widget.index,
  );

  @override
  void initState() {
    super.initState();
    widget.scrollback.register(_delegate);
  }

  @override
  void didUpdateWidget(_SelectableLine old) {
    super.didUpdateWidget(old);
    // The list recycles rows, so the same delegate can find itself standing
    // for a different line. Its index has to follow, or the row that starts a
    // selection would be decided from where it used to be.
    _delegate.index = widget.index;
  }

  @override
  void dispose() {
    widget.scrollback.unregister(_delegate);
    _delegate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SelectionContainer(delegate: _delegate, child: widget.child);
}

/// A labelled hairline across the scrollback: the change of day, or where
/// the unread messages start.
///
/// Out of the selection, like the other annotations: "Yesterday" is not
/// something anyone said.
class _Rule extends StatelessWidget {
  const _Rule({required this.label, this.loud = false});

  final String label;

  /// In the accent rather than muted — for the one rule that is an
  /// instruction ("start here") rather than a landmark.
  final bool loud;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = loud ? t.accent : t.muted;
    final rule = Expanded(
      child: Container(
        height: Tokens.hairline,
        color: loud ? t.accent.withValues(alpha: 0.5) : t.rule,
      ),
    );
    return SelectionContainer.disabled(
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: context.layout.gutter,
          vertical: 6,
        ),
        child: Row(
          children: [
            rule,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            rule,
          ],
        ),
      ),
    );
  }
}

/// The way back down, for a reader who has scrolled up or opened at the
/// first unread line. Carries how many messages have landed at the bottom
/// meanwhile, so "latest" has a size.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: 'Jump to latest',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Touchable(
            onTap: onTap,
            borderRadius: BorderRadius.circular(18),
            builder: (context, touch) => AnimatedContainer(
              duration: context.motion.fast,
              curve: Motion.curve,
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.alphaBlend(
                  t.surfaceHover.withValues(alpha: touch.wash),
                  t.surface,
                ),
                border: Border.all(color: t.rule, width: Tokens.hairline),
              ),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 20,
                color: t.text,
              ),
            ),
          ),
          if (count > 0)
            Positioned(
              top: -7,
              right: -7,
              child: IgnorePointer(child: CountBadge(count: count)),
            ),
        ],
      ),
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
    final t = context.tokens;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: context.layout.gutter,
        vertical: 3,
      ),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(color: t.muted, fontSize: 11.5, height: 1.3),
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
    this.card,
    this.onPersonTap,
  });

  final ChatLine line;
  final bool showSender;
  final AppSettings settings;

  /// What the user has written about the sender, if anything.
  final PersonCard? card;
  final ValueChanged<String>? onPersonTap;

  /// How much of the row an own-message block may take before it wraps. Wide
  /// enough for a sentence, narrow enough that the block reads as a block.
  static const _ownWidth = 0.78;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final message = line.message!;
    final mine = message.isSelf;
    final gutter = context.layout.gutter;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSender)
          // Kept out of the selection rather than stripped back out of it
          // afterwards. Nick and clock time are the app's annotation on what
          // someone said, not part of it, and a quote that drags them along
          // is a quote that has to be tidied up by hand every time.
          SelectionContainer.disabled(
            child: _SenderLabel(
              message: message,
              at: line.at,
              mine: mine,
              settings: settings,
              card: card,
              onTap: onPersonTap == null
                  ? null
                  : () => onPersonTap!(message.sender),
            ),
          ),
        _MessageBody(message: message, renderColors: settings.renderColors),
      ],
    );

    // Own messages sit on the right in a flat, tinted block; everyone else's
    // are plain on the left. Alignment alone was tried first and was not
    // enough — in a busy channel the eye needs a shape to find, not an edge.
    // No tails, no shadow: the block is the only ornament.
    final Widget body = mine
        ? LayoutBuilder(
            builder: (context, constraints) => Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * _ownWidth,
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: t.own,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  padding: const EdgeInsets.fromLTRB(9, 3, 9, 5),
                  child: content,
                ),
              ),
            ),
          )
        : content;

    // A colour on the leading edge, running the full height of every one of
    // someone's rows — the grouped continuation lines that show no name
    // included. The sender label alone carried the colour before, which meant
    // a person the user had deliberately coloured barely changed on screen:
    // most of what they say is a continuation line with no label to tint.
    //
    // A chosen colour stands almost at full strength, because choosing it was
    // the point; a colour a nick merely hashes to is a faint hint, so a busy
    // channel gains a set of quiet spines rather than a row of bright bars.
    // A mention outranks both: it takes the edge in its own rule, as before.
    final hasCardColor = card?.color != null;
    final personColor = mine
        ? null
        : card?.color ??
              (settings.colorNicks ? NickPalette.of(message.sender, t) : null);
    final Color? edge = line.isMention
        ? t.mentionRule
        : personColor?.withValues(alpha: hasCardColor ? 0.9 : 0.4);
    final edgeWidth = line.isMention ? 2.0 : (edge != null ? 3.0 : 0.0);

    return Container(
      width: double.infinity,
      // A wash, not a shout. The rule on the leading edge is what actually
      // catches the eye when scanning a long channel.
      decoration: BoxDecoration(
        color: line.isMention ? t.mention : null,
        border: edgeWidth > 0
            ? Border(
                left: BorderSide(color: edge!, width: edgeWidth),
              )
            : null,
      ),
      // The leading rule eats into the gutter rather than adding to it, so the
      // text starts on the same vertical line whether or not a row has one.
      padding: EdgeInsets.fromLTRB(
        gutter - edgeWidth,
        settings.density.verticalPadding,
        gutter,
        settings.density.verticalPadding,
      ),
      child: body,
    );
  }
}

class _SenderLabel extends StatelessWidget {
  const _SenderLabel({
    required this.message,
    required this.at,
    required this.mine,
    required this.settings,
    this.card,
    this.onTap,
  });

  final rust.ChatMessage message;
  final DateTime at;
  final bool mine;
  final AppSettings settings;
  final PersonCard? card;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Privilege is plain text, straight from the server's ISUPPORT — never a
    // badge, and never a hardcoded @/+ that would break on networks with
    // halfop or owner prefixes.
    final prefix = message.senderPrefix ?? '';
    // Your own nick keeps the accent whatever the palette says: it is the one
    // name that should look like the app's, not like a stranger's.
    // A colour the user chose for this person comes before the one their
    // nick hashes to.
    final color = mine
        ? t.accent
        : card?.color ??
              (settings.colorNicks
                  ? NickPalette.of(message.sender, t)
                  : t.muted);

    // The name the user gave them, if any; the nick is one hover away.
    final shown = card?.alias ?? message.sender;
    Widget nick = Text(
      '$prefix$shown',
      style: TextStyle(
        color: color,
        fontSize: 11.5,
        fontWeight: FontWeight.w600,
      ),
    );
    if (card?.alias != null) {
      nick = Tooltip(message: message.sender, child: nick);
    }
    if (onTap != null) {
      nick = MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: nick,
        ),
      );
    }
    // Once per run of messages, beside the name. A time on every line was
    // tried and was noise: the label says who and when, the lines under it
    // say what.
    final time = settings.showTimestamps
        ? Text(
            settings.formatTime(at),
            style: TextStyle(
              color: t.muted,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          )
        : null;

    return Padding(
      padding: EdgeInsets.only(
        top: settings.density == Density.compact ? 3 : 5,
        bottom: 1,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (card?.hasPicture ?? false) ...[
            Avatar(card: card, size: 16),
            const SizedBox(width: 6),
          ],
          nick,
          if (time != null) ...[const SizedBox(width: 7), time],
        ],
      ),
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message, required this.renderColors});

  final rust.ChatMessage message;

  /// When false, bold and italics still apply but sender-chosen colours are
  /// dropped — the styling that carries meaning is kept, the decoration is not.
  final bool renderColors;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final base = TextStyle(color: t.text, fontSize: 14, height: 1.4);

    // Actions read in the third person; notices are services rather than
    // people, and the classic -nick- form is worth keeping so they are
    // instantly distinguishable.
    final leading = message.isAction
        ? '• '
        : message.isNotice
        ? '-${message.sender}- '
        : '';

    final style = message.isAction
        ? base.copyWith(fontStyle: FontStyle.italic, color: t.text)
        : message.isNotice
        ? base.copyWith(color: t.muted)
        : base;

    // `Text.rich` rather than the bare `RichText` this used to be: a `Text`
    // registers itself with whatever selection is in scope, and a hand-built
    // `RichText` does not — it would draw identically and be the one thing on
    // the screen that could not be selected.
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          if (leading.isNotEmpty)
            TextSpan(
              text: leading,
              style: style.copyWith(color: t.faint),
            ),
          ...message.spans.map((span) => _span(span, style, renderColors, t)),
        ],
      ),
    );
  }

  /// Map one sanitised run from the core onto a Flutter span.
  ///
  /// The text is already free of control characters, so nothing here needs to
  /// re-sanitise; only the styling flags matter.
  static TextSpan _span(
    rust.TextSpan span,
    TextStyle base,
    bool colors,
    Tokens t,
  ) {
    final s = span.style;
    final background = colors ? MircPalette.background(s.bg) : null;
    // Contrast is measured against whatever this run actually sits on, so a
    // server-chosen foreground can never vanish into its own background.
    final surface = background ?? t.bg;

    var style = base.copyWith(
      fontWeight: s.bold ? FontWeight.w700 : null,
      fontStyle: s.italic ? FontStyle.italic : null,
      fontFamily: s.monospace ? Fonts.mono : null,
      fontFamilyFallback: s.monospace ? Fonts.monoFallback : null,
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
        color: background ?? t.bg,
        backgroundColor: style.color ?? t.text,
      );
    }

    return TextSpan(text: span.text, style: style);
  }
}
