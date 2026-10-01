import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, TapGestureRecognizer;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, HapticFeedback;
import 'package:flutter/rendering.dart' show SelectedContent;

import '../model/marks.dart';
import '../model/people.dart';
import '../model/session.dart';
import '../model/settings.dart';
import '../rust/api/types.dart' as rust;
import '../text/markdown.dart';
import '../theme.dart';
import 'avatar.dart';
import 'count_badge.dart';
import 'layout.dart';
import 'link.dart';
import 'menu.dart';
import 'motion.dart';
import 'nick_color.dart';
import 'touchable.dart';

/// A handle on a [MessageView], for the screen around it to point at a line.
///
/// Search results, pinned messages and saved messages all end the same way:
/// scroll the scrollback to one line and light it up. The view owns the
/// scrolling — only it knows which rows are built — so this is how a bar
/// above it asks.
class MessageViewController {
  _MessageViewState? _view;

  /// Scroll to [line] and flash it. False when it is not in the scrollback.
  Future<bool> reveal(ChatLine line) async =>
      await _view?._reveal(line) ?? false;
}

/// The scrollback for one conversation.
class MessageView extends StatefulWidget {
  const MessageView({
    super.key,
    required this.conversation,
    this.profileId,
    this.onPersonTap,
    this.onReply,
    this.onMention,
    this.onQuote,
    this.onLoadOlder,
    this.controller,
    this.highlight,
  });

  final Conversation conversation;

  /// Reply to a line quoting only part of it — the part selected.
  final void Function(ChatLine line, String excerpt)? onQuote;

  /// Fetch the page of history above the top. Returns how many lines came.
  final Future<int> Function()? onLoadOlder;

  final MessageViewController? controller;

  /// Text to light up wherever it appears — what is being searched for.
  final String? highlight;

  /// Which network this is, for what the user has written about the people
  /// on it. Null draws everyone as the server names them.
  final String? profileId;

  /// A name in the scrollback was tapped.
  final ValueChanged<String>? onPersonTap;

  /// The user asked to reply to a line — by swiping it, or with the button
  /// beside it. Null offers neither.
  final ValueChanged<ChatLine>? onReply;

  /// The user asked to address someone — "Mention" in a message's menu.
  final ValueChanged<String>? onMention;

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

  /// What the last build drew, kept for a tap on a quote to search.
  List<ChatLine> _lines = const [];
  List<_Group> _groups = const [];

  /// The line a tapped quote pointed at, lit up for a moment on arrival.
  final _flash = ValueNotifier<ChatLine?>(null);

  /// Unread mentions not yet jumped to, oldest first: the ones after the
  /// marker when the view opened, and any that land while reading above.
  final _mentions = ValueNotifier<List<ChatLine>>(const []);

  /// What is selected in the scrollback right now, for "reply with quote".
  String? _selected;

  /// Whether a page of older history is on its way, so reaching the top
  /// twice in a row does not ask twice.
  bool _loadingOlder = false;

  @override
  void initState() {
    super.initState();
    _marker = widget.conversation.unreadMarker;
    _controller.addListener(_onScroll);
    widget.controller?._view = this;
    final marker = _marker;
    if (marker != null) {
      final lines = widget.conversation.lines;
      final from = lines.indexOf(marker);
      if (from >= 0) {
        _mentions.value = [
          for (var i = from; i < lines.length; i++)
            if (lines[i].isMention && !lines[i].isSelf) lines[i],
        ];
      }
    }
  }

  @override
  void didUpdateWidget(MessageView old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      if (old.controller?._view == this) old.controller?._view = null;
      widget.controller?._view = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._view == this) widget.controller?._view = null;
    _controller.dispose();
    _away.dispose();
    _arrived.dispose();
    _flash.dispose();
    _mentions.dispose();
    super.dispose();
  }

  /// Near the top, with more above in the store: fetch it.
  ///
  /// The list is anchored at its bottom, so lines put in front would push
  /// what is on screen down by however tall they are. The scroll position is
  /// moved by the same amount once they are laid out, which keeps the line
  /// being read exactly where it was.
  Future<void> _maybeLoadOlder() async {
    final load = widget.onLoadOlder;
    if (load == null || _loadingOlder || !_controller.hasClients) return;
    if (!widget.conversation.hasOlder) return;
    final position = _controller.position;
    if (position.pixels > position.minScrollExtent + 300) return;
    _loadingOlder = true;
    final before = position.maxScrollExtent - position.pixels;
    try {
      final added = await load();
      if (!mounted || added == 0 || _split) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_controller.hasClients) return;
      final after = _controller.position.maxScrollExtent - before;
      _controller.jumpTo(
        after.clamp(
          _controller.position.minScrollExtent,
          _controller.position.maxScrollExtent,
        ),
      );
    } finally {
      _loadingOlder = false;
    }
  }

  /// Go to the next unread mention, and stop offering it.
  Future<void> _jumpToMention() async {
    final pending = _mentions.value;
    if (pending.isEmpty) return;
    _mentions.value = pending.sublist(1);
    await _reveal(pending.first);
  }

  void _onScroll() {
    // A jump that landed short of a bottom still being measured is not the
    // user scrolling up, and must not be read as one.
    if (!_controller.hasClients || _settling > 0) return;
    final position = _controller.position;
    final pinned = position.pixels >= position.maxScrollExtent - 40;
    _pinnedToBottom = pinned;
    _away.value = !pinned;
    // Reaching the bottom is reading what was there — mentions included.
    if (pinned) {
      _arrived.value = 0;
      if (_mentions.value.isNotEmpty) _mentions.value = const [];
    }
    if (position.pixels <= position.minScrollExtent + 300) {
      _maybeLoadOlder();
    }
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
      final mentioned = <ChatLine>[];
      if (_lastLine != null) {
        for (var i = all.length - 1; i >= 0; i--) {
          if (identical(all[i], _lastLine)) break;
          if (all[i].isSystem) continue;
          arrived++;
          if (all[i].isSelf) spoke = true;
          if (all[i].isMention) mentioned.insert(0, all[i]);
        }
      }
      if (mentioned.isNotEmpty && !_pinnedToBottom && !spoke) {
        _mentions.value = [..._mentions.value, ...mentioned];
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined, size: 36, color: t.faint),
            const SizedBox(height: 10),
            Text(
              'No messages yet — say hello.',
              style: TextStyle(color: t.muted, fontSize: 13.5),
            ),
          ],
        ),
      );
    }

    // Once per build rather than once per row. `DateTime.now()` is a syscall
    // on every platform, and asking it the same question fifteen times inside
    // one frame cannot get fifteen different answers worth having.
    final now = DateTime.now();
    final arrivedAfter = now.subtract(_arrival);

    final groups = _group(lines, markerIndex);
    _lines = lines;
    _groups = groups;
    // Where the unread rule lands, as a group. A rule always starts a group,
    // so the marker's line is always the first of one.
    final markerGroup = markerIndex <= 0
        ? -1
        : groups.indexWhere((g) => g.start == markerIndex);

    Widget row(int g) => _row(
      g,
      groups: groups,
      lines: lines,
      markerIndex: markerIndex,
      arrivedAfter: arrivedAfter,
      now: now,
      settings: settings,
    );

    final split = _split && markerGroup > 0;
    final slivers = split
        ? [
            // Older rows grow upward from the anchor, so their indices run
            // backwards and the padding that reads as `top` lands at the far
            // end — above the oldest line, where it belongs.
            SliverPadding(
              padding: const EdgeInsets.only(top: 10),
              sliver: SliverList.builder(
                itemCount: markerGroup,
                itemBuilder: (context, i) => row(markerGroup - 1 - i),
              ),
            ),
            SliverPadding(
              key: _centerKey,
              padding: const EdgeInsets.only(bottom: 10),
              sliver: SliverList.builder(
                itemCount: groups.length - markerGroup,
                itemBuilder: (context, i) => row(markerGroup + i),
              ),
            ),
          ]
        : [
            SliverPadding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              sliver: SliverList.builder(
                itemCount: groups.length,
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
            onSelectionChanged: (content) => _selected = content?.plainText,
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
        // Above the way down, the way to what was said *to* you: each press
        // goes to the next unread mention, oldest first, the way a messenger's
        // @ button does.
        Positioned(
          right: context.layout.gutter,
          bottom: 64,
          child: ValueListenableBuilder<List<ChatLine>>(
            valueListenable: _mentions,
            builder: (context, pending, _) => Appear(
              child: pending.isEmpty
                  ? null
                  : _JumpToMention(
                      key: const ValueKey('mention'),
                      count: pending.length,
                      onTap: _jumpToMention,
                    ),
            ),
          ),
        ),
      ],
    );
  }

  /// Split the scrollback into what is drawn as one piece: a system line on
  /// its own, or a *bubble* — one person's lines from within the same minute.
  ///
  /// The minute is the unit because it is the unit the time is shown in: a
  /// bubble carries one time, in its corner, and everything inside it was
  /// said then. A new minute is a new bubble with its own time, even from the
  /// same person mid-thought, so no line is ever further than one bubble from
  /// when it was said.
  ///
  /// A reply always starts a bubble of its own, because its quote goes on
  /// top, and so does anything a rule (a new day, the first unread line) falls
  /// in front of.
  static List<_Group> _group(List<ChatLine> lines, int markerIndex) {
    final groups = <_Group>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final previous = i > 0 ? lines[i - 1] : null;
      final joins =
          previous != null &&
          !line.isSystem &&
          i != markerIndex &&
          line.message!.replyTo == null &&
          _sameSpeaker(previous, line) &&
          _sameMinute(previous.at, line.at);
      if (joins) {
        groups.last.end = i + 1;
      } else {
        groups.add(_Group(i, i + 1));
      }
    }
    return groups;
  }

  static bool _sameSpeaker(ChatLine a, ChatLine b) =>
      !a.isSystem &&
      !b.isSystem &&
      a.message!.sender == b.message!.sender &&
      a.message!.isSelf == b.message!.isSelf;

  static bool _sameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;

  /// Whether two bubbles belong to one *run*: the same person, a few minutes
  /// apart, nothing in between. A run shows its name once, on top, and its
  /// bubbles sit close together with their inner corners tucked in — the way
  /// a stretch of someone talking reads as one turn.
  static bool _sameRun(ChatLine a, ChatLine b) =>
      _sameSpeaker(a, b) &&
      AppSettings.sameDay(a.at, b.at) &&
      b.at.difference(a.at).inMinutes < 5;

  Widget _row(
    int g, {
    required List<_Group> groups,
    required List<ChatLine> lines,
    required int markerIndex,
    required DateTime arrivedAfter,
    required DateTime now,
    required AppSettings settings,
  }) {
    final group = groups[g];
    final first = lines[group.start];
    final previous = group.start > 0 ? lines[group.start - 1] : null;
    final newDay =
        previous == null || !AppSettings.sameDay(previous.at, first.at);
    final unreadStart = group.start == markerIndex;
    final ruled = newDay || unreadStart;

    Widget body;
    if (first.isSystem) {
      body = _SelectableLine(
        index: group.start,
        scrollback: _selection,
        child: Arrive(
          play: group.start >= _freshFrom && first.at.isAfter(arrivedAfter),
          child: _SystemLine(text: first.system!),
        ),
      );
    } else {
      final last = lines[group.end - 1];
      final next = group.end < lines.length ? lines[group.end] : null;
      final nextRuled =
          next != null &&
          (group.end == markerIndex || !AppSettings.sameDay(last.at, next.at));
      final startsRun = ruled || !_sameRun(previous, first);
      final endsRun = next == null || nextRuled || !_sameRun(last, next);
      final message = first.message!;
      final reply = message.replyTo;
      body = _Bubble(
        key: GlobalObjectKey(first),
        lines: lines.sublist(group.start, group.end),
        firstIndex: group.start,
        scrollback: _selection,
        freshFrom: _freshFrom,
        arrivedAfter: arrivedAfter,
        startsRun: startsRun,
        endsRun: endsRun,
        settings: settings,
        card: widget.profileId == null
            ? null
            : People.instance.of(widget.profileId!, message.sender),
        quoted: reply == null ? null : _original(reply, before: group.start),
        flash: _flash,
        profileId: widget.profileId,
        conversation: widget.conversation.name,
        highlight: widget.highlight,
        selection: () => _selected,
        onPersonTap: widget.onPersonTap,
        onReply: widget.onReply,
        onQuote: widget.onQuote,
        onMention: widget.onMention,
        onQuoteTap: reply == null ? null : () => _showOriginal(reply, g),
      );
    }

    // Rules ride inside the row they precede rather than being rows of their
    // own, so every row here is still exactly one group.
    if (ruled) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (newDay)
            _DayChip(label: AppSettings.describeDay(first.at, now: now)),
          if (unreadStart) const _Rule(label: 'New messages', loud: true),
          body,
        ],
      );
    }
    return body;
  }

  /// The line [reply] answers, if it is still in the scrollback: by id when
  /// the server tags messages, otherwise by who said it and how it began.
  /// Searched backwards from the reply, since what is answered is nearly
  /// always just above it.
  ChatLine? _original(rust.ReplyRef reply, {required int before}) {
    final lines = _lines;
    final msgid = reply.msgid;
    final nick = reply.nick.toLowerCase();
    final start = reply.excerpt.endsWith('…')
        ? reply.excerpt.substring(0, reply.excerpt.length - 1)
        : reply.excerpt;
    for (var i = before - 1; i >= 0; i--) {
      final message = lines[i].message;
      if (message == null) continue;
      if (msgid != null && message.msgid == msgid) return lines[i];
      if (msgid == null &&
          nick.isNotEmpty &&
          message.sender.toLowerCase() == nick &&
          _plain(message).startsWith(start)) {
        return lines[i];
      }
    }
    return null;
  }

  static String _plain(rust.ChatMessage message) =>
      message.spans.map((s) => s.text).join().replaceAll(RegExp(r'\s+'), ' ');

  /// Scroll to what the reply in group [from] answers, and make it blink.
  ///
  /// The list is lazy, so the original may not be built yet and there is
  /// nothing to scroll *to*. So it scrolls *towards* it a screen at a time,
  /// each frame checking whether the row has been built, and settles on it
  /// the moment it has.
  Future<void> _showOriginal(rust.ReplyRef reply, int from) async {
    final groups = _groups;
    final target = _original(reply, before: groups[from].start);
    if (target == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(
          content: Text('The original is no longer in the scrollback.'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    await _reveal(target);
  }

  /// Scroll to [target] and make it blink.
  ///
  /// The list is lazy, so the line may not be built yet and there is nothing
  /// to scroll *to*. So it scrolls *towards* it a screen at a time, each frame
  /// checking whether the row has been built, and settles on it the moment it
  /// has.
  Future<bool> _reveal(ChatLine target) async {
    final groups = _groups;
    final lineIndex = _lines.indexOf(target);
    if (lineIndex < 0) return false;
    final g = groups.lastIndexWhere((group) => group.start <= lineIndex);
    if (g < 0) return false;
    final anchor = _lines[groups[g].start];
    final slow = context.motion.slow;

    for (var attempt = 0; attempt < 60 && mounted; attempt++) {
      final built = GlobalObjectKey(anchor).currentContext;
      if (built != null && built.mounted) {
        await Scrollable.ensureVisible(
          built,
          alignment: 0.3,
          duration: slow,
          curve: Motion.curve,
        );
        _flash.value = target;
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        if (mounted && identical(_flash.value, target)) _flash.value = null;
        return true;
      }
      final range = _selection.builtRange();
      if (range == null || !_controller.hasClients) return false;
      final position = _controller.position;
      final step = position.viewportDimension * 0.9;
      final up = lineIndex < range.$1;
      final to = (position.pixels + (up ? -step : step)).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if (to == position.pixels) return false;
      _controller.jumpTo(to);
      await WidgetsBinding.instance.endOfFrame;
    }
    return false;
  }
}

/// A run of lines drawn as one piece. See [_MessageViewState._group].
class _Group {
  _Group(this.start, this.end);

  /// Indices into the visible lines: [start] inclusive, [end] exclusive.
  final int start;
  int end;
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

  /// The first and last line currently built, or null if none are. Every
  /// built line registers here, which makes this the cheapest way to know
  /// where the lazy list is without asking it.
  (int, int)? builtRange() {
    if (_rows.isEmpty) return null;
    var low = _rows.first.index;
    var high = low;
    for (final row in _rows) {
      if (row.index < low) low = row.index;
      if (row.index > high) high = row.index;
    }
    return (low, high);
  }
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
            borderRadius: BorderRadius.circular(21),
            builder: (context, touch) => AnimatedContainer(
              duration: context.motion.fast,
              curve: Motion.curve,
              width: 42,
              height: 42,
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

/// The way to the next unread mention. An @ in the accent, with how many are
/// left — the count is what makes it worth pressing more than once.
class _JumpToMention extends StatelessWidget {
  const _JumpToMention({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: count == 1
          ? 'Jump to mention'
          : 'Jump to the next of $count mentions',
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Touchable(
            onTap: onTap,
            borderRadius: BorderRadius.circular(21),
            builder: (context, touch) => AnimatedContainer(
              duration: context.motion.fast,
              curve: Motion.curve,
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color.alphaBlend(
                  t.surfaceHover.withValues(alpha: touch.wash),
                  t.surface,
                ),
                border: Border.all(color: t.accent, width: 1.2),
              ),
              child: Icon(
                Icons.alternate_email_rounded,
                size: 19,
                color: t.accent,
              ),
            ),
          ),
          Positioned(
            top: -7,
            right: -7,
            child: IgnorePointer(
              child: CountBadge(count: count, highlighted: true),
            ),
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

/// The date, as a small pill floating over the scrollback where the day
/// changes — "Today", "Yesterday", "3 March". A chip rather than a rule
/// across the whole width: it names the day without drawing a line through
/// the conversation.
///
/// Out of the selection, like the other annotations: "Yesterday" is not
/// something anyone said.
class _DayChip extends StatelessWidget {
  const _DayChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(Tokens.radiusXL),
              border: Border.all(color: t.rule, width: Tokens.hairline),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: t.muted,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One bubble: one person's lines from within one minute.
///
/// Everyone gets one — the user's own on the right in the accent tint, other
/// people's on the left on [Tokens.bubble] — so a busy channel reads as a
/// stack of shapes the eye can step through rather than a wall of text. The
/// time sits in the bubble's bottom corner, tucked in beside the last line
/// the way a messenger does it, so it is always there and never costs a line
/// of its own.
///
/// Bubbles in the same run (see [_MessageViewState._sameRun]) sit close
/// together and round their inner corners less, which is what makes a run
/// read as one turn of the conversation; the last one keeps a small corner on
/// the sender's side, where a messenger would draw a tail.
class _Bubble extends StatefulWidget {
  const _Bubble({
    super.key,
    required this.lines,
    required this.firstIndex,
    required this.scrollback,
    required this.freshFrom,
    required this.arrivedAfter,
    required this.startsRun,
    required this.endsRun,
    required this.settings,
    required this.flash,
    this.profileId,
    this.conversation,
    this.highlight,
    this.selection,
    this.card,
    this.quoted,
    this.onPersonTap,
    this.onReply,
    this.onQuote,
    this.onMention,
    this.onQuoteTap,
  });

  /// Where this bubble is, for pinning and saving its lines.
  final String? profileId;
  final String? conversation;

  /// Text to light up, when a search is open.
  final String? highlight;

  /// What is selected in the scrollback at the moment of asking.
  final String? Function()? selection;

  final void Function(ChatLine line, String excerpt)? onQuote;

  final List<ChatLine> lines;

  /// Where [lines] begin in the scrollback, for the selection.
  final int firstIndex;
  final _ScrollbackSelection scrollback;
  final int freshFrom;
  final DateTime arrivedAfter;
  final bool startsRun;
  final bool endsRun;
  final AppSettings settings;

  /// The line being pointed out after a tap on a quote, if it is one of ours.
  final ValueListenable<ChatLine?> flash;

  /// What the user has written about the sender, if anything.
  final PersonCard? card;

  /// The line the first one here replies to, when it is still loaded.
  final ChatLine? quoted;

  final ValueChanged<String>? onPersonTap;
  final ValueChanged<ChatLine>? onReply;
  final ValueChanged<String>? onMention;
  final VoidCallback? onQuoteTap;

  /// How much of the row a bubble may take before it wraps. Wide enough for a
  /// sentence, narrow enough that it reads as a bubble and the other side of
  /// the conversation stays visible.
  static const _maxWidth = 0.78;
  static const _maxWidthCompact = 0.86;

  /// Everything but the pointers that drag to select text. Named by what is
  /// left out rather than what is let in, because not every finger says it is
  /// one: injected and some OEM touch events arrive as
  /// [PointerDeviceKind.unknown], and a whitelist of `touch` alone silently
  /// ignored them.
  static final _swipeDevices = {
    for (final kind in PointerDeviceKind.values)
      if (kind != PointerDeviceKind.mouse && kind != PointerDeviceKind.trackpad)
        kind,
  };

  /// How far a swipe has to travel before letting go of it is a reply.
  static const _swipeToReply = 56.0;
  static const _swipeMax = 76.0;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> {
  /// How far the bubble has been dragged towards a reply.
  double _drag = 0;

  /// Which line a swipe or the hover button is about.
  int _target = 0;
  bool _hovered = false;

  late List<GlobalKey> _lineKeys = _keys();

  List<GlobalKey> _keys() =>
      List.generate(widget.lines.length, (_) => GlobalKey());

  @override
  void didUpdateWidget(_Bubble old) {
    super.didUpdateWidget(old);
    if (old.lines.length != widget.lines.length) {
      final keys = _keys();
      for (var i = 0; i < keys.length && i < _lineKeys.length; i++) {
        keys[i] = _lineKeys[i];
      }
      _lineKeys = keys;
      _target = _target.clamp(0, widget.lines.length - 1);
    }
  }

  /// The line under [global], so a swipe replies to what the finger was on.
  int _lineAt(Offset global) {
    for (var i = 0; i < _lineKeys.length; i++) {
      final box = _lineKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final top = box.localToGlobal(Offset.zero).dy;
      if (global.dy < top + box.size.height) return i;
    }
    return widget.lines.length - 1;
  }

  void _reply(int i) => widget.onReply?.call(widget.lines[i]);

  /// What holding a message offers — or right-clicking it: reply to it,
  /// quote part of it, copy it, address its author, pin it, save it. The way
  /// messengers do it, and the way to reach all of it without aiming at a
  /// small button.
  ///
  /// [at] is where the pointer was; a long press opens it on the line.
  Future<void> _menu(int i, {Offset? at}) async {
    final line = widget.lines[i];
    final message = line.message!;
    final box = _lineKeys[i].currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    if (at == null) HapticFeedback.selectionClick();
    final where = at ?? box.localToGlobal(box.size.center(Offset.zero));
    final text = message.spans.map((s) => s.text).join();

    // Part of this line selected: that part is what a quote is of, and what
    // Copy copies. Selected text from somewhere else is not this line's.
    final selected = widget.selection?.call()?.trim();
    final excerpt =
        selected != null && selected.isNotEmpty && text.contains(selected)
        ? selected
        : null;

    final profileId = widget.profileId;
    final conversation = widget.conversation;
    final marks = Marks.instance;
    final canMark = profileId != null && conversation != null;
    final available = canMark && marks.available;
    final pinned =
        canMark &&
        marks.isMarked(MarkKind.pinned, profileId, conversation, line);
    final saved =
        canMark &&
        marks.isMarked(MarkKind.saved, profileId, conversation, line);
    const needsHistory = 'Turn on message history in Privacy';

    final choice = await showPointerMenu<String>(
      context,
      at: where,
      items: [
        if (widget.onReply != null)
          const PopupMenuItem(
            value: 'reply',
            child: MenuRow(icon: Icons.reply_rounded, label: 'Reply'),
          ),
        if (widget.onQuote != null && excerpt != null)
          const PopupMenuItem(
            value: 'quote',
            child: MenuRow(
              icon: Icons.format_quote_rounded,
              label: 'Reply with quote',
            ),
          ),
        PopupMenuItem(
          value: 'copy',
          child: MenuRow(
            icon: Icons.copy_rounded,
            label: excerpt == null ? 'Copy' : 'Copy selection',
          ),
        ),
        if (widget.onMention != null && !message.isSelf)
          PopupMenuItem(
            value: 'mention',
            child: MenuRow(
              icon: Icons.alternate_email_rounded,
              label: 'Mention ${message.sender}',
            ),
          ),
        if (canMark) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'pin',
            enabled: available,
            child: MenuRow(
              icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
              label: pinned ? 'Unpin' : 'Pin',
              enabled: available,
            ),
          ),
          PopupMenuItem(
            value: 'save',
            enabled: available,
            child: MenuRow(
              icon: saved
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
              label: saved ? 'Remove from saved' : 'Save',
              enabled: available,
            ),
          ),
          // Said rather than left to be guessed: a greyed-out row with no
          // reason is a row that looks broken.
          if (!available)
            const PopupMenuItem(
              enabled: false,
              height: 28,
              child: Text(needsHistory, style: TextStyle(fontSize: 11.5)),
            ),
        ],
      ],
    );
    if (!mounted) return;
    void say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
    switch (choice) {
      case 'reply':
        _reply(i);
      case 'quote':
        widget.onQuote?.call(line, excerpt!);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: excerpt ?? text));
        if (!mounted) return;
        say(excerpt == null ? 'Message copied' : 'Selection copied');
      case 'mention':
        widget.onMention?.call(message.sender);
      case 'pin':
        final now = await marks.toggle(
          MarkKind.pinned,
          profileId!,
          conversation!,
          line,
        );
        if (mounted) say(now ? 'Pinned' : 'Unpinned');
      case 'save':
        final now = await marks.toggle(
          MarkKind.saved,
          profileId!,
          conversation!,
          line,
        );
        if (mounted) say(now ? 'Saved' : 'Removed from saved');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final settings = widget.settings;
    final first = widget.lines.first.message!;
    final mine = first.isSelf;
    final compact = context.layout.isCompact;
    final gutter = context.layout.gutter;
    final mention = widget.lines.any((l) => l.isMention);

    // A colour on the leading edge of someone's bubbles — every one of them,
    // not only the one that carries the name. A chosen colour stands almost
    // at full strength, because choosing it was the point; a colour a nick
    // merely hashes to is a faint hint. A mention outranks both.
    final hasCardColor = widget.card?.color != null;
    final personColor = mine
        ? null
        : widget.card?.color ??
              (settings.colorNicks ? NickPalette.of(first.sender, t) : null);
    final Color? edge = mention
        ? t.mentionRule
        : personColor?.withValues(alpha: hasCardColor ? 0.9 : 0.4);
    final edgeWidth = mention ? 2.5 : (edge != null ? 3.0 : 0.0);

    final fill = mine
        ? t.own
        : mention
        ? Color.alphaBlend(t.mention, t.bubble)
        : t.bubble;

    // Big corners outside, tucked-in corners where one bubble of a run meets
    // the next, and a small one at the foot of the run on the sender's side.
    const big = Radius.circular(Tokens.radiusL);
    const tucked = Radius.circular(6);
    const tail = Radius.circular(4);
    final near = (
      top: widget.startsRun ? big : tucked,
      bottom: widget.endsRun ? tail : tucked,
    );
    final radius = mine
        ? BorderRadius.only(
            topLeft: big,
            bottomLeft: big,
            topRight: near.top,
            bottomRight: near.bottom,
          )
        : BorderRadius.only(
            topLeft: near.top,
            bottomLeft: near.bottom,
            topRight: big,
            bottomRight: big,
          );

    final timeStyle = TextStyle(
      color: t.muted,
      fontSize: 10.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final time = settings.showTimestamps
        ? settings.formatTime(widget.lines.last.at)
        : null;

    final children = <Widget>[
      if (!mine && widget.startsRun)
        // Kept out of the selection rather than stripped back out of it
        // afterwards. The name is the app's annotation on what someone said,
        // not part of it.
        SelectionContainer.disabled(
          child: _SenderLabel(
            message: first,
            settings: settings,
            card: widget.card,
            onTap: widget.onPersonTap == null
                ? null
                : () => widget.onPersonTap!(first.sender),
          ),
        ),
      if (first.replyTo case final reply?)
        _Quote(reply: reply, original: widget.quoted, onTap: widget.onQuoteTap),
      for (var i = 0; i < widget.lines.length; i++)
        _line(
          context,
          i,
          time: i == widget.lines.length - 1 ? time : null,
          timeStyle: timeStyle,
        ),
    ];

    Widget bubble = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: fill, borderRadius: radius),
      child: Container(
        decoration: BoxDecoration(
          border: edgeWidth > 0
              ? Border(
                  left: BorderSide(color: edge!, width: edgeWidth),
                )
              : null,
        ),
        padding: EdgeInsets.fromLTRB(
          12 - edgeWidth.clamp(0, 3),
          settings.density == Density.compact ? 5 : 7,
          10,
          settings.density == Density.compact ? 4 : 6,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: children,
        ),
      ),
    );

    // Replying, by the input to hand: a swipe towards the middle on a touch
    // screen, the way messengers do it, and a button beside the bubble for a
    // mouse. Touch only for the swipe — a horizontal drag with a mouse is how
    // text is selected, and taking that away would be a worse trade.
    if (widget.onReply != null) {
      bubble = GestureDetector(
        supportedDevices: _Bubble._swipeDevices,
        onHorizontalDragStart: (d) => _target = _lineAt(d.globalPosition),
        onHorizontalDragUpdate: (d) {
          final delta = mine ? -d.delta.dx : d.delta.dx;
          final before = _drag;
          setState(() => _drag = (_drag + delta).clamp(0, _Bubble._swipeMax));
          if (before < _Bubble._swipeToReply &&
              _drag >= _Bubble._swipeToReply) {
            HapticFeedback.selectionClick();
          }
        },
        onHorizontalDragEnd: (_) {
          if (_drag >= _Bubble._swipeToReply) _reply(_target);
          setState(() => _drag = 0);
        },
        onHorizontalDragCancel: () => setState(() => _drag = 0),
        child: Transform.translate(
          offset: Offset(mine ? -_drag : _drag, 0),
          child: bubble,
        ),
      );
    }

    final hoverButton = widget.onReply == null || compact
        ? null
        : AnimatedOpacity(
            opacity: _hovered ? 1 : 0,
            duration: context.motion.fast,
            child: IgnorePointer(
              ignoring: !_hovered,
              child: IconButton(
                onPressed: () => _reply(_target),
                icon: const Icon(Icons.reply_rounded, size: 18),
                color: t.muted,
                tooltip: 'Reply',
                visualDensity: VisualDensity.compact,
              ),
            ),
          );

    // Shown behind a swipe in progress, filling in as it passes the point
    // where letting go would reply.
    final swipeHint = _drag <= 0
        ? null
        : Positioned(
            left: mine ? null : 0,
            right: mine ? 0 : null,
            top: 0,
            bottom: 0,
            child: Center(
              child: Opacity(
                opacity: (_drag / _Bubble._swipeToReply).clamp(0, 1),
                child: Icon(
                  Icons.reply_rounded,
                  size: 20,
                  color: _drag >= _Bubble._swipeToReply ? t.accent : t.muted,
                ),
              ),
            ),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          gutter,
          widget.startsRun
              ? (settings.density == Density.compact ? 6 : 10)
              : settings.density.verticalPadding,
          gutter,
          settings.density.verticalPadding,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => Stack(
            children: [
              ?swipeHint,
              Row(
                mainAxisAlignment: mine
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (mine && hoverButton != null) hoverButton,
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth:
                          constraints.maxWidth *
                          (compact
                              ? _Bubble._maxWidthCompact
                              : _Bubble._maxWidth),
                    ),
                    child: bubble,
                  ),
                  if (!mine && hoverButton != null) hoverButton,
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One line of the bubble: its own selection container, so a copy across
  /// several comes out as several lines, and its own flash when a quote
  /// elsewhere points at it.
  Widget _line(
    BuildContext context,
    int i, {
    required String? time,
    required TextStyle timeStyle,
  }) {
    final t = context.tokens;
    final line = widget.lines[i];
    final index = widget.firstIndex + i;
    final fresh =
        index >= widget.freshFrom && line.at.isAfter(widget.arrivedAfter);

    final body = _MessageBody(
      message: line.message!,
      renderColors: widget.settings.renderColors,
      markdown: widget.settings.markdown,
      highlight: widget.highlight,
      time: time,
      timeStyle: timeStyle,
    );

    // A right-click is the mouse's long press. It takes over from the
    // selection's own menu on a message, which only ever offered Copy and
    // Select all; this one offers Copy too, of the selection when there is
    // one.
    return MouseRegion(
      key: _lineKeys[i],
      onEnter: (_) => _target = i,
      child: GestureDetector(
        onSecondaryTapUp: (d) => _menu(i, at: d.globalPosition),
        child: GestureDetector(
          supportedDevices: _Bubble._swipeDevices,
          onLongPress: () => _menu(i),
          child: ValueListenableBuilder<ChatLine?>(
            valueListenable: widget.flash,
            builder: (context, flashing, child) => AnimatedContainer(
              duration: context.motion.slow,
              curve: Motion.curve,
              margin: EdgeInsets.only(top: i == 0 ? 0 : 3),
              decoration: BoxDecoration(
                color: identical(flashing, line)
                    ? t.accent.withValues(alpha: 0.18)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: child,
            ),
            child: _SelectableLine(
              index: index,
              scrollback: widget.scrollback,
              child: Arrive(play: fresh, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a reply answers, drawn on top of it: a bar in the accent, who said
/// it, and how it began. Tapping it goes there.
class _Quote extends StatelessWidget {
  const _Quote({required this.reply, this.original, this.onTap});

  final rust.ReplyRef reply;

  /// The line itself, when it is still in the scrollback. It fills in what a
  /// reply sent by tag alone does not say.
  final ChatLine? original;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final message = original?.message;
    final nick = reply.nick.isNotEmpty ? reply.nick : message?.sender ?? '';
    final excerpt = reply.excerpt.isNotEmpty
        ? reply.excerpt
        : message?.spans.map((s) => s.text).join() ?? 'a message';

    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4, top: 2),
        child: Touchable(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Tokens.radiusS),
          builder: (context, touch) => Container(
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                t.surfaceHover.withValues(alpha: touch.wash),
                t.accent.withValues(alpha: 0.10),
              ),
              borderRadius: BorderRadius.circular(Tokens.radiusS),
            ),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 3, color: t.accent),
                  Flexible(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 10, 5),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (nick.isNotEmpty)
                            Text(
                              nick,
                              style: TextStyle(
                                color: t.accent,
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            excerpt,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: t.muted, fontSize: 12.5),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SenderLabel extends StatelessWidget {
  const _SenderLabel({
    required this.message,
    required this.settings,
    this.card,
    this.onTap,
  });

  final rust.ChatMessage message;
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
    // A colour the user chose for this person comes before the one their
    // nick hashes to.
    final color =
        card?.color ??
        (settings.colorNicks ? NickPalette.of(message.sender, t) : t.muted);

    // The name the user gave them, if any; the nick is one hover away.
    final shown = card?.alias ?? message.sender;
    Widget nick = Text(
      '$prefix$shown',
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
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

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (card?.hasPicture ?? false) ...[
            Avatar(card: card, size: 16),
            const SizedBox(width: 6),
          ],
          Flexible(child: nick),
        ],
      ),
    );
  }
}

class _MessageBody extends StatefulWidget {
  const _MessageBody({
    required this.message,
    required this.renderColors,
    this.markdown = true,
    this.highlight,
    this.time,
    this.timeStyle,
  });

  final rust.ChatMessage message;

  /// Whether `**this**` is drawn bold. See [decorate].
  final bool markdown;

  /// Text to light up wherever it appears in the line.
  final String? highlight;

  /// The bubble's time, when this is its last line. Tucked in beside the end
  /// of the text when there is room on its last line, and on a line of its
  /// own at the right when there is not — the way a messenger does it.
  final String? time;
  final TextStyle? timeStyle;

  /// Between the end of the text and the time.
  static const _timeGap = 10.0;

  /// When false, bold and italics still apply but sender-chosen colours are
  /// dropped — the styling that carries meaning is kept, the decoration is not.
  final bool renderColors;

  @override
  State<_MessageBody> createState() => _MessageBodyState();
}

class _MessageBodyState extends State<_MessageBody> {
  /// One per link in the line. Held so they can be disposed: a recogniser
  /// is a gesture arena entrant, and one leaked per rebuild adds up in a
  /// scrollback of thousands.
  final List<TapGestureRecognizer> _links = [];

  /// The line, decorated, for the message and setting it was made for —
  /// rebuilt only when either changes, not on every scroll.
  DecoratedLine? _decorated;
  rust.ChatMessage? _decoratedFor;
  bool? _decoratedWith;

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  void _disposeLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  DecoratedLine _decorate() {
    if (!identical(_decoratedFor, widget.message) ||
        _decoratedWith != widget.markdown) {
      _decoratedFor = widget.message;
      _decoratedWith = widget.markdown;
      _decorated = decorate(widget.message.spans, markdown: widget.markdown);
    }
    return _decorated!;
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final renderColors = widget.renderColors;
    final timeStyle = widget.timeStyle;
    final t = context.tokens;
    final base = TextStyle(color: t.text, fontSize: 14.5, height: 1.45);

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

    final decorated = _decorate();
    final runStyle = decorated.quote ? style.copyWith(color: t.muted) : style;
    _disposeLinks();
    final runs = <InlineSpan>[];
    for (final run in decorated.runs) {
      final link = run.link;
      TapGestureRecognizer? tap;
      if (link != null) {
        tap = TapGestureRecognizer()..onTap = () => openLink(context, link);
        _links.add(tap);
      }
      runs.addAll(
        _span(
          rust.TextSpan(text: run.text, style: run.style),
          runStyle,
          renderColors,
          t,
          link: tap,
          highlight: widget.highlight,
        ),
      );
    }

    // `Text.rich` rather than the bare `RichText` this used to be: a `Text`
    // registers itself with whatever selection is in scope, and a hand-built
    // `RichText` does not — it would draw identically and be the one thing on
    // the screen that could not be selected.
    final span = TextSpan(
      style: runStyle,
      children: [
        if (leading.isNotEmpty)
          TextSpan(
            text: leading,
            style: style.copyWith(color: t.faint),
          ),
        ...runs,
      ],
    );
    Widget text = Text.rich(span);
    // A line that began `> ` is somebody quoting: drawn with a bar down its
    // side, the way the quote on a reply is, and the marker itself gone.
    if (decorated.quote) {
      text = Container(
        padding: const EdgeInsets.only(left: 8),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: t.faint, width: 3)),
        ),
        child: text,
      );
    }
    final time = widget.time;
    if (time == null) return text;

    // Out of the selection: the time is the app's, not what anyone said.
    final stamp = SelectionContainer.disabled(
      child: Text(time, style: timeStyle),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // Measured exactly as `Text` will draw it: under the inherited
        // default style (the theme's letter spacing and font fallbacks
        // included), or the guess about where the last line ends is wrong
        // and the time lands on top of it.
        final inherited = DefaultTextStyle.of(context).style;
        final scaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        final paragraph = TextPainter(
          text: TextSpan(style: inherited, children: [span]),
          textDirection: direction,
          textScaler: scaler,
        )..layout(maxWidth: constraints.maxWidth);
        final clock = TextPainter(
          text: TextSpan(style: inherited.merge(timeStyle), text: time),
          textDirection: direction,
          textScaler: scaler,
        )..layout();
        final lines = paragraph.computeLineMetrics();
        final lastLine = lines.isEmpty ? 0.0 : lines.last.width;
        final needed =
            lastLine +
            _MessageBody._timeGap +
            clock.width +
            (decorated.quote ? 11 : 0);
        final single = lines.length <= 1;
        final width = paragraph.width;
        paragraph.dispose();
        clock.dispose();

        // One short line: the time follows it.
        if (single && needed <= constraints.maxWidth) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(child: text),
              const SizedBox(width: _MessageBody._timeGap),
              Padding(padding: const EdgeInsets.only(bottom: 1), child: stamp),
            ],
          );
        }
        // Several lines, the last with room to spare: the time sits in it.
        if (!single && needed <= width) {
          return Stack(
            children: [
              text,
              Positioned(right: 0, bottom: 1, child: stamp),
            ],
          );
        }
        // No room: a line of its own, at the right.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(alignment: AlignmentDirectional.centerStart, child: text),
            stamp,
          ],
        );
      },
    );
  }

  /// Map one sanitised run from the core onto a Flutter span.
  ///
  /// The text is already free of control characters, so nothing here needs to
  /// re-sanitise; only the styling flags matter.
  static List<TextSpan> _span(
    rust.TextSpan span,
    TextStyle base,
    bool colors,
    Tokens t, {
    TapGestureRecognizer? link,
    String? highlight,
  }) {
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

    // A link reads as one: the accent, underlined, and a hand over it.
    if (link != null) {
      style = style.copyWith(
        color: t.accent,
        decoration: TextDecoration.underline,
        decorationColor: t.accent.withValues(alpha: 0.6),
      );
    }

    TextSpan piece(String text, TextStyle style) => TextSpan(
      text: text,
      style: style,
      recognizer: link,
      mouseCursor: link == null ? null : SystemMouseCursors.click,
    );

    final needle = highlight?.trim().toLowerCase() ?? '';
    if (needle.isEmpty) return [piece(span.text, style)];

    // What is being searched for, lit up wherever it falls in the run.
    final lit = style.copyWith(
      backgroundColor: t.accent.withValues(alpha: 0.35),
    );
    final haystack = span.text.toLowerCase();
    final out = <TextSpan>[];
    var at = 0;
    while (true) {
      final found = haystack.indexOf(needle, at);
      if (found < 0) break;
      if (found > at) out.add(piece(span.text.substring(at, found), style));
      out.add(piece(span.text.substring(found, found + needle.length), lit));
      at = found + needle.length;
    }
    if (at < span.text.length) out.add(piece(span.text.substring(at), style));
    return out;
  }
}
