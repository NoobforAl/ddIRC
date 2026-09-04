import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../rust/api/client.dart' as core;
import '../rust/api/types.dart';
import 'errors.dart';
import 'log.dart';
import 'notice.dart';
import 'settings.dart';
import 'transfer.dart';

/// How many lines to retain per conversation.
///
/// A busy channel produces thousands an hour; keeping all of them would grow
/// without bound on a device that may stay connected for days.
const _maxLinesPerConversation = 2000;

/// What a system line is about.
///
/// Only [SystemKind.presence] is noise a user might reasonably want gone; the
/// rest report something that actually changed, so they are never hidden.
enum SystemKind { presence, topic, mode, connection }

/// One rendered line: either a real message or a subordinate system notice.
class ChatLine {
  ChatLine.message(this.message, this.at) : system = null, kind = null;
  ChatLine.system(this.system, this.at, this.kind) : message = null;

  final ChatMessage? message;
  final String? system;
  final SystemKind? kind;

  /// Stamped on receipt.
  ///
  /// IRC carries no timestamp unless the server offers the IRCv3 `server-time`
  /// capability, so local receipt time is what every client without it shows.
  final DateTime at;

  bool get isSystem => system != null;
  bool get isMention => message?.isMention ?? false;
  bool get isSelf => message?.isSelf ?? false;
}

/// A channel or a direct message, with its own scrollback and unread count.
class Conversation {
  Conversation({
    required this.name,
    required this.isChannel,
    this.pending = false,
  });

  final String name;
  final bool isChannel;

  /// A first message from someone we have never spoken to, not yet answered
  /// for.
  ///
  /// It is a real conversation with real lines in it — the message has already
  /// arrived and pretending otherwise would mean losing it — but it has not
  /// been let in: no tab, never made active on its own, and the composer stays
  /// shut until it is accepted. On IRC anyone can message anyone, so an inbox
  /// that opens itself on demand is a thing other people control.
  bool pending;

  final List<ChatLine> lines = [];
  List<MemberView> members = const [];
  String? topic;

  /// Offers waiting to be answered, and transfers in flight.
  ///
  /// Held apart from [lines] because they are not lines: they change while you
  /// look at them, and the scrollback is a record of what was said. Only the
  /// outcome of a transfer becomes a line, once it has stopped moving.
  final List<FileTransfer> transfers = [];

  /// Messages since this conversation was last looked at.
  int unread = 0;

  /// Unread messages that mention us — surfaced more prominently, because a
  /// direct mention is worth interrupting for in a way ambient chatter is not.
  int unreadMentions = 0;

  void add(
    ChatLine line, {
    required bool active,
    NotifyLevel notify = NotifyLevel.all,
  }) {
    lines.add(line);
    if (lines.length > _maxLinesPerConversation) {
      lines.removeRange(0, lines.length - _maxLinesPerConversation);
    }
    // System noise (joins, parts) should not make a channel look like it has
    // something to say.
    if (active || line.isSystem) return;
    // A muted channel still collects its messages; it just stops asking to be
    // read. Nothing is ever dropped on the floor.
    switch (notify) {
      case NotifyLevel.none:
        return;
      case NotifyLevel.mentions:
        if (!line.isMention) return;
      case NotifyLevel.all:
        break;
    }
    unread++;
    if (line.isMention) unreadMentions++;
  }

  void markRead() {
    unread = 0;
    unreadMentions = 0;
  }

  /// Apply one change to the roster, keeping it in the order the core sorts.
  ///
  /// [previous] is the nick the row is currently filed under and [member] what
  /// belongs there now — null when they have gone. A rename is not a special
  /// case here: it is a row removed from one place and put back in another,
  /// which is also exactly what being opped is.
  ///
  /// The order comes from [MemberView.sortKey], which the core computes with
  /// the same rule it sorts a whole roster by. Deciding where a nick goes here
  /// would mean a second copy of that rule, in another language, drifting from
  /// the first the day either changes.
  void applyMemberChange(String previous, MemberView? member) {
    final at = _indexOf(previous);
    if (at == null && member == null) return;

    // A new list rather than a mutation, because `MemberList` compares list
    // identity to decide whether anything moved. Mutating in place would leave
    // it looking at a list it believes it has already seen — and copying a few
    // hundred references is far less than the roster this event exists to
    // avoid sending.
    final next = List<MemberView>.of(members);
    if (at != null) next.removeAt(at);
    if (member != null) next.insert(_placeFor(next, member.sortKey), member);
    members = next;
  }

  /// Where the row for [nick] is, if it is here at all.
  ///
  /// Exact first, because the core sends the spelling the roster was given.
  /// The case-insensitive second pass is the belt to that brace: nicks are
  /// case-insensitive on IRC, and a row that could not be found would be a
  /// duplicate a moment later.
  int? _indexOf(String nick) {
    for (var i = 0; i < members.length; i++) {
      if (members[i].nick == nick) return i;
    }
    final folded = nick.toLowerCase();
    for (var i = 0; i < members.length; i++) {
      if (members[i].nick.toLowerCase() == folded) return i;
    }
    return null;
  }

  /// The index [key] sorts to in an already-ordered [list].
  static int _placeFor(List<MemberView> list, String key) {
    var low = 0;
    var high = list.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (list[mid].sortKey.compareTo(key) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

/// Owns everything the UI renders for one server connection.
///
/// Reads the event stream from the Rust core and fans events out into
/// per-conversation buffers. All protocol decisions (mention detection, control
/// The slash commands the composer understands.
///
/// One list, read both by [SessionModel.submit] and by the composer's
/// suggestion popup, so the app can never offer a command and then reject it
/// as unknown — which is exactly what a hand-maintained second list would
/// drift into.
enum SlashCommand {
  join('join', '<#channel>', 'Join a channel'),
  msg('msg', '<nick> <message>', 'Send someone a private message'),
  query('query', '<nick>', 'Open a conversation with someone, saying nothing'),
  me('me', '<action>', 'Say what you are doing, in the third person'),
  nick('nick', '<nickname>', 'Change your nickname'),
  topic('topic', '<text>', 'Set the topic of this channel'),
  part('part', '[reason]', 'Leave this channel');

  const SlashCommand(this.name, this.usage, this.description);

  final String name;

  /// What follows the command. Angle brackets required, square optional —
  /// the convention every other IRC client already taught the user.
  final String usage;
  final String description;

  String get usageLine => '/$name $usage';

  /// Commands whose name starts with [prefix] — the composer's text with its
  /// leading slash removed. Declaration order is kept, so the list narrows in
  /// place instead of reshuffling under the cursor.
  static List<SlashCommand> matching(String prefix) {
    final needle = prefix.toLowerCase();
    return values.where((c) => c.name.startsWith(needle)).toList();
  }

  static SlashCommand? parse(String name) {
    for (final command in values) {
      if (command.name == name) return command;
    }
    return null;
  }
}

/// character stripping, own-message echo) already happened in the core; this
/// class only routes and presents.
class SessionModel extends ChangeNotifier {
  SessionModel({
    required this.connectionId,
    required this.profileId,
    required this.config,
    required this.settings,
    this.onLine,
    this.onRead,
  }) : _nick = config.nickname;

  /// Called for every line filed into a conversation, if anyone is listening.
  ///
  /// Injected rather than reached for, like [settings] beside it, so this class
  /// stays testable without a window, a platform or a notification service —
  /// and so that nothing about whether the app is in front leaks down here.
  final void Function(Conversation, ChatLine)? onLine;

  /// Called when a conversation is opened, and so has been seen.
  ///
  /// The counterpart to [onLine], and the reason it exists separately: a
  /// notification that has been acted on should stop asking. Reading a message
  /// on the desktop while the phone is in a pocket is exactly the case where
  /// one screen has to take back what another is still showing.
  final void Function(Conversation)? onRead;

  final BigInt connectionId;

  /// Which saved profile this connection came from.
  ///
  /// Carried so per-channel settings are scoped to the network: `#chat` on one
  /// server has nothing to do with `#chat` on another, and muting one must not
  /// mute the other.
  final String profileId;

  /// What we connected with. Held so the server dialog can show the user which
  /// host and port they are actually on, rather than what they last typed.
  final ServerConfig config;

  /// Consulted for per-channel notification levels; never mutated from here.
  final AppSettings settings;

  final Map<String, Conversation> _conversations = {};
  final List<String> _order = [];

  /// The conversations open as tabs, in the order they were opened.
  ///
  /// Deliberately not the same set as [_order]. Joining opens a tab, but
  /// closing one only stops showing it — you stay in the channel, exactly as
  /// closing an editor tab does not delete the file. The list on the left is
  /// everything you are in; this is what you have open.
  final List<String> _tabs = [];

  /// Channels the user has just asked to be in, waiting for the server to say
  /// they are.
  ///
  /// The whole difference between a channel that opens a tab and one that does
  /// not. A `JOIN` for ourselves looks identical on the wire whether it came
  /// from `/join`, from the browser, or from the profile's list being replayed
  /// at registration — and only the first two are the user opening something
  /// right now. Nothing else can tell them apart after the fact, so the
  /// intention is recorded before the request goes out.
  ///
  /// Keys, not names, because the server may answer `#Foo` with `#foo`.
  final Set<String> _requested = {};

  /// Whether this session has put the user anywhere yet.
  ///
  /// Connecting should land somewhere rather than on an empty screen, and the
  /// first channel to arrive is where. Deliberately not "is anything open
  /// right now": that question answers yes again the moment somebody closes
  /// their last tab, which would make a channel cycling on the server reopen a
  /// tab they had just shut.
  bool _landed = false;

  /// The server's channel directory, most populated first.
  ///
  /// Empty until somebody asks: `LIST` is the largest thing this connection
  /// ever receives, and sending it unprompted at every connect would make
  /// every connect expensive to pay for a browser most people open rarely.
  List<ChannelListing> _directory = const [];
  bool _directoryLoading = false;
  bool _directoryTruncated = false;

  /// Gives up waiting for a server that answered `LIST` with silence.
  ///
  /// Some servers refuse the command outright and say nothing at all, and a
  /// browser spinning for ever is a worse answer than an empty one.
  Timer? _directoryTimeout;

  String _nick;
  String? _active;

  /// The one thing the app is currently telling the user, if any.
  ///
  /// On the model rather than on the screen, because the things worth saying
  /// no longer all originate from a button press: a transfer fails minutes
  /// after it was started, and a screen-local `String? _error` had nowhere for
  /// that to arrive.
  Notice? _notice;

  /// Clears [_notice] once it has been up long enough. Held so it can be
  /// cancelled — by the next notice, by a dismissal, or by disposal.
  Timer? _noticeTimer;
  String? _network;
  ConnectionStatus _status = const ConnectionStatus.connecting();

  /// Why the connection is in the state it is, when the core said.
  ///
  /// Kept because "Disconnected" on its own stopped being enough the moment
  /// the core learned to give up: a connection that has stopped trying has to
  /// say what went wrong, or the user is looking at a retry button with no
  /// idea whether pressing it can possibly help.
  String? _statusDetail;
  AuthOutcome? _auth;
  StreamSubscription<IrcEvent>? _subscription;

  String get nick => _nick;
  String? get network => _network;
  ConnectionStatus get status => _status;

  /// The reason behind [status], if there was one.
  String? get statusDetail => _statusDetail;

  /// Whether this connection goes through a proxy.
  ///
  /// Read by the transfer rows, because it changes what an offer can do: a
  /// reverse offer asks us to listen, listening means disclosing an address,
  /// and the core refuses that behind a proxy. Better to say so on the row
  /// than to offer an Accept button whose only outcome is a refusal.
  bool get usesProxy => config.proxy != null;

  /// What to show above the composer, or null for nothing.
  Notice? get notice => _notice;
  AuthOutcome? get auth => _auth;

  /// Conversations in the order they were opened.
  ///
  /// Materialised rather than a view over a lazy `map`. An
  /// [UnmodifiableListView] wrapping a mapped iterable indexes by walking, so
  /// the `ListView.builder` that reads this was doing O(n) work per row and
  /// O(n^2) per build. Rebuilt only when the set of conversations changes,
  /// which is a join or a part, not a message.
  List<Conversation> get conversations => _conversationsCache ??=
      UnmodifiableListView([for (final key in _order) _conversations[key]!]);

  Conversation? get active => _active == null ? null : _conversations[_active];

  /// Open tabs, left to right.
  List<Conversation> get tabs => _tabsCache ??= UnmodifiableListView([
    for (final key in _tabs) _conversations[key]!,
  ]);

  List<Conversation>? _conversationsCache;
  List<Conversation>? _tabsCache;

  /// Drop both projections. Cheap, and called from every mutation of either
  /// list, so a stale one is not something a future edit can reintroduce by
  /// forgetting which of the two it touched.
  void _invalidateLists() {
    _conversationsCache = null;
    _tabsCache = null;
  }

  /// Whether this session is already in [name].
  ///
  /// Read by the browser, which offers channels the user may well be sitting
  /// in — a directory that quietly omitted them would read as those channels
  /// having closed.
  bool isIn(String name) => _conversations.containsKey(_key(name));

  /// The channels this server has, as far as they have arrived.
  List<ChannelListing> get directory => _directory;

  /// Whether an answer is still coming.
  bool get directoryLoading => _directoryLoading;

  /// Whether what is in [directory] is the busiest of more than it holds.
  bool get directoryTruncated => _directoryTruncated;

  /// Ask the server for its channels.
  ///
  /// Cheap to call again — the core ignores a second request while one is in
  /// flight — but the results already held are kept on screen while the new
  /// ones arrive, so reopening the browser never empties it.
  Future<void> browseChannels() async {
    if (_directoryLoading) return;
    _directoryLoading = true;
    _directoryTimeout?.cancel();
    _directoryTimeout = Timer(const Duration(seconds: 45), () {
      if (_disposed || !_directoryLoading) return;
      _directoryLoading = false;
      notifyListeners();
    });
    notifyListeners();
    try {
      await core.listChannels(id: connectionId);
    } catch (e) {
      _directoryLoading = false;
      _directoryTimeout?.cancel();
      raiseNotice(Notice.error(describeError(e)));
    }
  }

  int get totalUnread =>
      _conversations.values.fold(0, (sum, c) => sum + c.unread);

  int get totalMentions =>
      _conversations.values.fold(0, (sum, c) => sum + c.unreadMentions);

  bool get isConnected => _status is ConnectionStatus_Connected;

  /// Feed one event in as though it had come from the core.
  ///
  /// The seam this class was already written for — see the note on [onLine] —
  /// extended to the event stream, so which channels open a tab can be checked
  /// without a socket, a server or the native library loaded.
  @visibleForTesting
  void receiveForTesting(IrcEvent event) => _onEvent(event);

  /// The half of [joinChannel] that does not touch the core: record that the
  /// user asked for this channel.
  ///
  /// Exposed because the other half cannot run in a test — there is no native
  /// library to send through, and a send that fails deliberately forgets the
  /// intention, which is the correct behaviour and also the one that makes the
  /// interesting case untestable through the front door.
  @visibleForTesting
  void requestForTesting(String channel) => _requested.add(_key(channel));

  void start() {
    // Fed from the Rust network runtime, so a flooding channel never stalls
    // the UI thread.
    _subscription = core.eventStream(id: connectionId).listen(_onEvent);
  }

  /// Repaint at most once per frame, however many events arrived in it.
  ///
  /// The core delivers one event per line, and a busy channel delivers a lot
  /// of them — a netsplit rejoining `#Debian` is several hundred inside a
  /// second. Notifying per event meant a full rebuild of the rail, the
  /// channel list, the tab strip, the scrollback and the member list per
  /// *line*, and on a low-end phone the frame budget is gone long before the
  /// burst is. The screen can only show one frame anyway, so the extra
  /// rebuilds bought nothing that was ever displayed.
  ///
  /// A post-frame callback rather than a microtask, because each event
  /// arrives in its own turn of the event loop and a microtask would coalesce
  /// nothing. The cost is that a line appears a frame later than it used to;
  /// the gain is that it appears at all while a flood is in progress.
  ///
  /// User actions — selecting a conversation, closing a tab — still notify
  /// directly. Those are one-at-a-time and want the immediate answer.
  void _queueNotify() {
    if (_notifyQueued || _disposed) return;
    _notifyQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
    // A post-frame callback only runs if a frame runs. Nothing else has asked
    // for one when the app is idle, which is exactly when the first message
    // of a burst lands.
    SchedulerBinding.instance.scheduleFrame();
  }

  bool _notifyQueued = false;
  bool _disposed = false;

  /// Stop waiting out the reconnect backoff and try again now.
  ///
  /// The connection, and with it the scrollback, survives — this wakes the
  /// actor that is already counting down rather than replacing it. Harmless at
  /// any other moment: the core ignores it unless it is actually waiting.
  Future<void> retryNow() => core.reconnect(id: connectionId);

  @override
  void dispose() {
    _disposed = true;
    _noticeTimer?.cancel();
    _directoryTimeout?.cancel();
    _subscription?.cancel();
    core.disconnect(id: connectionId, reason: 'ddIRC');
    super.dispose();
  }

  /// Conversation keys are case-insensitive: IRC treats `#Foo` and `#foo` as
  /// one channel, and the server may use either casing at different times.
  String _key(String name) => name.toLowerCase();

  Conversation _conversationFor(
    String name, {
    required bool isChannel,
    bool pending = false,
    bool openTab = true,
  }) {
    final key = _key(name);
    final existing = _conversations[key];
    if (existing != null) return existing;

    final created = Conversation(
      name: name,
      isChannel: isChannel,
      pending: pending,
    );
    _conversations[key] = created;
    _order.add(key);
    _invalidateLists();
    // A request does neither of the two things below. Both are courtesies to
    // somewhere the user chose to be, and being messaged by a stranger is not
    // a choice they made — a tab opening and the screen changing under them is
    // exactly the control this is taking back.
    if (pending) return created;
    // The same argument, one step weaker, for a channel that arrived from the
    // profile's own list: being in it was decided once, when the network was
    // saved, and is not a decision to open it *now*. It goes in the list on
    // the left with everything else you are in, and the strip stays as short
    // as the number of things you actually opened.
    if (!openTab) return created;
    // Arriving somewhere you asked to be opens it. A channel joined from
    // /join or from the browser that did not appear in the strip would be
    // invisible until the user went looking for it in the list.
    _tabs.add(key);
    // The first conversation to appear becomes the active one, so the user is
    // never looking at an empty screen after joining.
    _active ??= key;
    return created;
  }

  /// Join a channel because the user just said to.
  ///
  /// The one door for a deliberate join — `/join`, the channel browser — and
  /// the only thing that separates them from the profile's list is that they
  /// come through here. Recording the intention before the request goes out is
  /// what lets the answer open a tab; a join that skipped this would land in
  /// the list on the left and nowhere else.
  Future<void> joinChannel(String channel, {String? key}) async {
    final name = channel.trim();
    if (name.isEmpty) return;
    _requested.add(_key(name));
    // Already in it — the browser will happily offer a channel you are in, and
    // the server will not send a second JOIN to answer with. Open it here
    // instead, so pressing Join is never a press that does nothing.
    if (_conversations.containsKey(_key(name))) {
      _requested.remove(_key(name));
      select(name);
      return;
    }
    try {
      await core.join(id: connectionId, channel: name, key: key);
    } catch (e) {
      // The intention outlives nothing: a request that never went out must not
      // leave a channel primed to open a tab if the server puts us in it later
      // for some other reason.
      _requested.remove(_key(name));
      raiseNotice(Notice.error(describeError(e)));
    }
  }

  /// Open a conversation with a person, without sending them anything.
  ///
  /// The counterpart to `/msg`, which only opens one as a side effect of
  /// saying something. Deciding to talk to someone and deciding what to say
  /// are two acts, and there is no reason the first should require the second.
  void openDirect(String nick) {
    final trimmed = nick.trim();
    if (trimmed.isEmpty) return;
    // Choosing to talk to someone answers, in advance, the question a request
    // would have asked — and unblocks them if they had been turned away
    // before. Without this, opening a conversation with a blocked nick would
    // give an empty room where nothing they said ever arrived, which is a
    // worse answer than either blocking or not.
    settings.accept(profileId, trimmed);
    final conversation = _conversationFor(trimmed, isChannel: false);
    conversation.pending = false;
    select(trimmed);
  }

  /// Let a stranger in.
  void acceptDirect(String nick) {
    final conversation = _conversations[_key(nick)];
    if (conversation == null || !conversation.pending) return;
    _accept(conversation);
  }

  void _accept(Conversation conversation) {
    conversation.pending = false;
    settings.accept(profileId, conversation.name);
    select(conversation.name);
  }

  /// Turn a stranger away, and stop being asked about them.
  ///
  /// The conversation goes rather than sitting in the list as a decision the
  /// user has already made. Blocking is what makes declining mean something:
  /// without it the same person simply asks again, and a refusal you have to
  /// repeat is not a refusal.
  void declineDirect(String nick) {
    final conversation = _conversations[_key(nick)];
    if (conversation == null || !conversation.pending) return;
    settings.block(profileId, conversation.name);
    // Answered, so anything still asking about it should stop. Declining is as
    // much a decision as accepting, and a notification left behind would go on
    // demanding one that has already been made.
    onRead?.call(conversation);
    _close(conversation.name);
    notifyListeners();
  }

  /// Say something to the user. Replaces whatever was there.
  ///
  /// One at a time, deliberately: a stack of notices above the composer is a
  /// wall nobody reads, and the most recent is almost always the relevant one.
  void raiseNotice(Notice? notice) {
    // Restarted even for an identical notice, because the same failure
    // happening twice is news the second time and should get its full ten
    // seconds rather than inheriting whatever was left of the first.
    _noticeTimer?.cancel();
    _noticeTimer = null;

    final changed = _notice != notice;
    _notice = notice;

    if (notice != null) {
      _noticeTimer = Timer(noticeLifetime, () {
        _noticeTimer = null;
        // Guarded: the session may have been disposed while this was pending,
        // and notifying listeners after that throws.
        if (_disposed) return;
        _notice = null;
        notifyListeners();
      });
    }

    if (changed) notifyListeners();
  }

  void dismissNotice() => raiseNotice(null);

  void select(String name) {
    final key = _key(name);
    if (!_conversations.containsKey(key)) return;
    // Picking something from the list opens it if it was closed, which is the
    // only way back to a tab the user shut.
    if (!_tabs.contains(key)) {
      _tabs.add(key);
      _invalidateLists();
    }
    _active = key;
    final conversation = _conversations[key]!;
    conversation.markRead();
    onRead?.call(conversation);
    notifyListeners();
  }

  /// Close a tab without leaving the conversation.
  ///
  /// Focus falls to the neighbour on the right, then the left — where the eye
  /// already is — rather than to whichever tab happens to be last.
  void closeTab(String name) {
    final key = _key(name);
    final index = _tabs.indexOf(key);
    if (index == -1) return;
    _tabs.removeAt(index);
    _invalidateLists();

    if (_active == key) {
      _active = _tabs.isEmpty ? null : _tabs[index.clamp(0, _tabs.length - 1)];
      if (_active != null) _conversations[_active]!.markRead();
    }
    notifyListeners();
  }

  void _addLine(
    String name,
    ChatLine line, {
    required bool isChannel,
    bool pending = false,
    bool openTab = true,
  }) {
    final conversation = _conversationFor(
      name,
      isChannel: isChannel,
      pending: pending,
      openTab: openTab,
    );
    conversation.add(
      line,
      active: _key(name) == _active,
      notify: settings.notifyFor(profileId, name),
    );
    _log(name, line);
    // Handed on with the conversation it landed in, so whoever is listening
    // can see whether it is a request, whether it is the one on screen, and
    // what the network is called. Deciding whether it is worth interrupting
    // someone for needs to know whether the app is even in front, which is not
    // something a session can answer.
    onLine?.call(conversation, line);
  }

  /// Mirror a line into the chat log, if one is being kept.
  ///
  /// The spans are flattened back to plain text rather than logged with their
  /// formatting: a log is read in a text editor, and mIRC colour codes would
  /// make it worse rather than more faithful.
  void _log(String name, ChatLine line) {
    if (!AppLog.instance.chatEnabled) return;
    final message = line.message;
    final text = message == null
        ? line.system ?? ''
        : '<${message.isAction ? '*' : ''}${message.sender}> '
              '${message.spans.map((s) => s.text).join()}';
    AppLog.instance.chat(
      network: _network ?? config.host,
      conversation: name,
      text: text,
    );
  }

  /// Status and error lines belong to whatever the user is currently reading;
  /// they are about the connection, not any one channel.
  void _addToActive(String text) {
    final target = active;
    if (target == null) {
      // Before any channel exists, keep a server console so early errors — a
      // ban, a bad password — are not lost.
      _conversationFor('server', isChannel: false).add(
        ChatLine.system(text, DateTime.now(), SystemKind.connection),
        active: true,
      );
      return;
    }
    target.add(
      ChatLine.system(text, DateTime.now(), SystemKind.connection),
      active: true,
    );
  }

  void _onEvent(IrcEvent event) {
    final now = DateTime.now();

    switch (event) {
      case IrcEvent_Status(:final status, :final detail):
        _status = status;
        _statusDetail = detail;
        final described = _describeStatus(status, detail);
        _addToActive(described);
        // The debug log's whole job: the sequence of connection states, and
        // the reason each one was entered. No message content reaches it.
        AppLog.instance.debug('[${_network ?? config.host}] $described');

      case IrcEvent_Registered(:final nick, :final network, :final auth):
        _nick = nick;
        _network = network;
        _auth = auth;
        _addToActive('registered on ${network ?? 'server'} as $nick');
        if (auth is AuthOutcome_NickServFallback) {
          _addToActive('SASL unavailable (${auth.reason}) — used NickServ');
        }

      case IrcEvent_NetworkNamed(:final network):
        _network = network;

      case IrcEvent_Message(:final message):
        final target = message.target;
        final (name, isChannel) = switch (target) {
          Target_Channel(:final name) => (name, true),
          Target_Direct(:final nick) => (nick, false),
        };
        // A blocked nick is dropped here, before anything: no conversation, no
        // unread count, no line in a log. Filtering later would mean the
        // message still landed somewhere, and a block that leaves a trace is a
        // block the user has to tidy up after.
        if (!isChannel &&
            !message.isSelf &&
            settings.isBlocked(profileId, name)) {
          return;
        }
        _addLine(
          name,
          ChatLine.message(message, now),
          isChannel: isChannel,
          // Only a stranger's opening line: someone with a conversation
          // already, someone previously accepted, and our own echo are all
          // people we have decided about. `_conversationFor` ignores this once
          // the conversation exists, so it is only ever read on the first one.
          pending:
              !isChannel &&
              !message.isSelf &&
              !settings.isAccepted(profileId, name),
        );

      case IrcEvent_Joined(:final channel, :final nick, :final isSelf):
        // Whether *this* join is something the user just did. A `/join`, a
        // channel picked in the browser and a click on the list all say so;
        // the profile's own list, arriving in a burst the moment registration
        // completes, says nothing and gets nothing.
        //
        // Consumed rather than read, so joining `#x`, parting, and being put
        // back in it by the server does not reopen a tab the user closed.
        final asked = isSelf && _requested.remove(_key(channel));
        _addLine(
          channel,
          ChatLine.system(
            isSelf ? 'you joined $channel' : '$nick joined',
            now,
            SystemKind.presence,
          ),
          isChannel: true,
          openTab: asked,
        );
        // Somewhere to be, and only that. The first channel to arrive is
        // opened so that connecting does not land on an empty screen; the
        // fifth is not, and the strip stays the length of what was asked for.
        if (isSelf && (asked || !_landed)) {
          _landed = true;
          select(channel);
        }

      case IrcEvent_ChannelList(
        :final channels,
        :final done,
        :final truncated,
      ):
        // Replaced, never appended to: each event carries the busiest of
        // everything the core has seen, so the previous one is a prefix of
        // this one and adding them together would show every channel twice.
        _directory = channels;
        _directoryTruncated = truncated;
        if (done) {
          _directoryLoading = false;
          _directoryTimeout?.cancel();
        }

      case IrcEvent_Parted(
        :final channel,
        :final nick,
        :final isSelf,
        :final reason,
      ):
        if (isSelf) {
          _close(channel);
        } else {
          _addLine(
            channel,
            ChatLine.system(
              '$nick left${_reason(reason)}',
              now,
              SystemKind.presence,
            ),
            isChannel: true,
          );
        }

      case IrcEvent_Quit(:final channel, :final nick, :final reason):
        _addLine(
          channel,
          ChatLine.system(
            '$nick quit${_reason(reason)}',
            now,
            SystemKind.presence,
          ),
          isChannel: true,
        );

      case IrcEvent_NickChanged(
        :final channel,
        :final old,
        :final new_,
        :final isSelf,
      ):
        if (isSelf) _nick = new_;
        _addLine(
          channel,
          ChatLine.system('$old is now $new_', now, SystemKind.presence),
          isChannel: true,
        );

      case IrcEvent_TopicChanged(:final channel, :final topic, :final setBy):
        final conversation = _conversationFor(channel, isChannel: true);
        conversation.topic = topic;
        conversation.add(
          ChatLine.system(
            setBy == null ? 'topic: $topic' : '$setBy set the topic: $topic',
            now,
            SystemKind.topic,
          ),
          active: _key(channel) == _active,
        );

      case IrcEvent_MemberList(:final channel, :final members):
        // A whole roster, which the core sends only when there is one to
        // replace: the end of a NAMES burst, and our own join. Replacing
        // wholesale is what makes those two moments authoritative.
        _conversationFor(channel, isChannel: true).members = members;

      case IrcEvent_MemberChanged(
        :final channel,
        :final previous,
        :final member,
      ):
        // Everything after that arrives one person at a time — an arrival, a
        // departure, a rename, an op, an away. The roster used to be told
        // about none of these, so a channel's member list was whatever it was
        // at the moment you walked in.
        _conversationFor(
          channel,
          isChannel: true,
        ).applyMemberChange(previous, member);

      case IrcEvent_ModeChanged(:final channel, :final by, :final affected):
        _addLine(
          channel,
          ChatLine.system(
            '${by ?? 'server'} changed modes: ${affected.join(', ')}',
            now,
            SystemKind.mode,
          ),
          isChannel: true,
        );

      case IrcEvent_MessagesDropped(:final channel, :final count):
        // Never swallowed: a silent gap would read as "nobody spoke".
        final text = '$count message(s) dropped — flood protection';
        if (channel == null) {
          _addToActive(text);
        } else {
          _addLine(
            channel,
            ChatLine.system(text, now, SystemKind.connection),
            isChannel: true,
          );
        }

      case IrcEvent_FileOffered(
        :final id,
        :final channel,
        :final from,
        :final offer,
      ):
        // Nothing has happened: the core reports an offer and never answers
        // one, so no connection exists and nothing has been sent back.
        //
        // Not shown at all unless file transfers are switched on. An offer
        // that cannot be accepted is a prompt to go and enable something,
        // which is not what an off switch should do — and the offer itself is
        // a stranger's text, so displaying it is the one thing that costs
        // anything here.
        if (!settings.fileTransfers) break;
        _addLine(
          channel,
          ChatLine.system(
            _describeOffer(from, offer),
            now,
            SystemKind.connection,
          ),
          isChannel: _looksLikeChannel(channel),
        );
        // The line above is the record; this is the thing with buttons on it.
        // Both, because the line survives the decision and the row does not.
        _conversationFor(
          channel,
          isChannel: _looksLikeChannel(channel),
        ).transfers.add(
          FileTransfer.offered(
            id: id,
            filename: offer.filename,
            from: from,
            total: offer.size,
            isReverse: offer.port == null,
          ),
        );

      case IrcEvent_FileTransferStarted(
        :final id,
        :final channel,
        :final filename,
        :final incoming,
        :final total,
      ):
        final conversation = _conversationFor(
          channel,
          isChannel: _looksLikeChannel(channel),
        );
        // An accepted offer becomes the transfer it turned into rather than
        // sitting beside it, so the row never shows both a decision already
        // made and the thing it decided.
        conversation.transfers.removeWhere((t) => t.id == id);
        conversation.transfers.add(
          FileTransfer.running(
            id: id,
            filename: filename,
            incoming: incoming,
            total: total,
          ),
        );

      case IrcEvent_FileTransferProgress(:final id, :final transferred):
        // Carries no channel — it is only ever read against a transfer that
        // was already placed when it started. Searching every conversation is
        // cheap next to the alternative of a name to keep in step.
        for (final conversation in _conversations.values) {
          for (final transfer in conversation.transfers) {
            if (transfer.id == id) {
              transfer.transferred = transferred;
              break;
            }
          }
        }

      case IrcEvent_FileTransferEnded(
        :final id,
        :final channel,
        :final filename,
        :final path,
        :final error,
      ):
        final conversation = _conversationFor(
          channel,
          isChannel: _looksLikeChannel(channel),
        );
        conversation.transfers.removeWhere((t) => t.id == id);
        // Two places, because they answer different questions. The line is the
        // record and will still make sense next week; the notice is the alert,
        // and without it a transfer that failed after two minutes would be a
        // muted grey line indistinguishable from someone joining.
        raiseNotice(
          noticeForTransfer(filename: filename, path: path, error: error),
        );
        // Now it is over it becomes a line, which is where something that has
        // stopped changing belongs — and where it will still make sense later.
        _addLine(
          channel,
          ChatLine.system(
            FileTransfer.describeOutcome(
              filename: filename,
              path: path,
              error: error,
            ),
            now,
            SystemKind.connection,
          ),
          isChannel: _looksLikeChannel(channel),
        );

      case IrcEvent_Error(:final message, :final fatal):
        _addToActive('error: $message');
        AppLog.instance.debug('[${_network ?? config.host}] error: $message');
        // Raised as well as logged. A server error used to be a muted grey
        // line in the scrollback, which is where it belongs as a record and
        // exactly the wrong place for it as an alert — being told the nick is
        // taken should not look like someone joining.
        raiseNotice(
          fatal
              ? Notice.error(message, detail: 'The connection cannot continue.')
              : Notice.error(message),
        );
    }
    _queueNotify();
  }

  /// Whether a routing target is a channel rather than a person.
  ///
  /// Only ever asked about a DCC offer, and only to decide the shape of a
  /// conversation that does not exist yet — every other event says which it is,
  /// because the core already knows. `#` is not the whole answer: `&`, `+` and
  /// `!` are channel prefixes too, and a `&channel` offer filed as a private
  /// message would open a second conversation for a room already on screen.
  static bool _looksLikeChannel(String target) =>
      target.isNotEmpty && '#&+!'.contains(target[0]);

  /// One line for a file someone has offered.
  ///
  /// The size is the sender's claim and is written as one — "says it is" —
  /// because nothing has verified it and a transfer that turns out to be ten
  /// times larger should not be able to say it was never warned about.
  String _describeOffer(String from, DccOffer offer) {
    final size = offer.size;
    // The one byte formatter, shared with the transfer rows. Two of them
    // meant the same file could be "2 KB" in the scrollback and "2.0 KB" in
    // the row above it, which is the kind of difference that looks like a bug
    // in the numbers rather than in the formatting.
    final howBig = size == null
        ? ''
        : ', says it is ${FileTransfer.describeSize(size)}';
    return '$from offered you "${offer.filename}"$howBig';
  }

  /// Leaving for real: the conversation is gone, so its tab goes with it.
  void _close(String channel) {
    final key = _key(channel);
    _conversations.remove(key);
    _order.remove(key);
    _tabs.remove(key);
    _invalidateLists();
    if (_active == key) {
      _active = _tabs.isNotEmpty
          ? _tabs.last
          : (_order.isEmpty ? null : _order.last);
      if (_active != null && !_tabs.contains(_active)) {
        _tabs.add(_active!);
        _invalidateLists();
      }
    }
  }

  static String _reason(String? reason) =>
      reason == null || reason.isEmpty ? '' : ' ($reason)';

  static String _describeStatus(ConnectionStatus status, String? detail) {
    final suffix = detail == null || detail.isEmpty ? '' : ': $detail';
    return switch (status) {
      ConnectionStatus_Disconnected() => 'disconnected$suffix',
      ConnectionStatus_Connecting() => 'connecting$suffix',
      ConnectionStatus_Registering() => 'registering$suffix',
      ConnectionStatus_Connected() => 'connected$suffix',
      ConnectionStatus_Reconnecting(:final retryInSecs, :final attempt) =>
        'reconnecting in ${retryInSecs}s (attempt $attempt)$suffix',
    };
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  /// Change our nickname. The server decides whether it sticks; the rename
  /// only lands in the UI once it comes back as a NICK event.
  Future<String?> changeNick(String nick) =>
      _run(() => core.setNick(id: connectionId, nick: nick.trim()));

  /// Set a channel topic, or clear it by passing an empty string.
  ///
  /// A server will reject this with a numeric if the channel is `+t` and we
  /// are not an operator; that arrives as an inline error like any other.
  Future<String?> setTopic(String channel, String topic) => _run(
    () =>
        core.setTopic(id: connectionId, channel: channel, topic: topic.trim()),
  );

  /// Offer a file to whoever this conversation is with.
  ///
  /// The path goes to the core, which reads it: the bytes never come back
  /// through Dart, so sending a large file costs no more memory than a small
  /// one. What comes back is a stream of progress events.
  Future<String?> sendFile(String target, String path) =>
      _run(() => core.sendFile(id: connectionId, target: target, path: path));

  /// Take up an offer, saving it into [directory].
  Future<String?> acceptTransfer(BigInt id, String directory) => _run(
    () =>
        core.acceptFile(id: connectionId, transferId: id, directory: directory),
  );

  /// Stop a transfer, or turn down an offer.
  ///
  /// Declining is silent — nothing is sent to whoever offered — so this is
  /// also how an offer is dismissed without answering it.
  Future<String?> cancelTransfer(BigInt id) {
    for (final conversation in _conversations.values) {
      conversation.transfers.removeWhere((t) => t.id == id);
    }
    notifyListeners();
    return _run(() => core.cancelTransfer(id: connectionId, transferId: id));
  }

  /// Leave a channel. The conversation closes when the server confirms.
  Future<String?> leave(String channel, {String? reason}) => _run(
    () => core.part_(
      id: connectionId,
      channel: channel,
      reason: (reason == null || reason.trim().isEmpty) ? null : reason.trim(),
    ),
  );

  /// Run one core call, turning a failure into a string the UI can show.
  static Future<String?> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      return '$e';
    }
    return null;
  }

  /// Interpret composer input, handling the slash commands users expect.
  ///
  /// Returns an error string to show inline, or null on success.
  Future<String?> submit(String input) async {
    final text = input.trim();
    if (text.isEmpty) return null;

    if (!text.startsWith('/')) {
      final target = active;
      if (target == null) return 'not in a channel';
      // The composer is disabled while a request is unanswered, so this is the
      // backstop rather than the gate. Answering someone you have not let in
      // would decide the question by accident, and it would tell them you are
      // there — which is most of what an unsolicited message is fishing for.
      if (target.pending) return 'accept the request first';
      await core.sendMessage(id: connectionId, target: target.name, text: text);
      return null;
    }

    final body = text.substring(1);
    final split = body.indexOf(' ');
    final verb = (split == -1 ? body : body.substring(0, split)).toLowerCase();
    final argument = split == -1 ? '' : body.substring(split + 1).trim();

    final command = SlashCommand.parse(verb);
    if (command == null) return 'unknown command: /$verb';

    // A known command missing its argument answers with its own usage line
    // rather than pretending not to recognise it, which is what the old
    // fall-through to "unknown command" did.
    String? usage() => 'usage: ${command.usageLine}';

    try {
      switch (command) {
        case SlashCommand.join:
          if (argument.isEmpty) return usage();
          await joinChannel(argument);
        case SlashCommand.part:
          final target = active;
          if (target == null) return 'not in a channel';
          await core.part_(
            id: connectionId,
            channel: target.name,
            reason: argument.isEmpty ? null : argument,
          );
        case SlashCommand.nick:
          if (argument.isEmpty) return usage();
          await core.setNick(id: connectionId, nick: argument);
        case SlashCommand.me:
          if (argument.isEmpty) return usage();
          final target = active;
          if (target == null) return 'not in a channel';
          await core.sendAction(
            id: connectionId,
            target: target.name,
            text: argument,
          );
        case SlashCommand.topic:
          if (argument.isEmpty) return usage();
          final target = active;
          if (target == null || !target.isChannel) {
            return 'not in a channel';
          }
          await core.setTopic(
            id: connectionId,
            channel: target.name,
            topic: argument,
          );
        case SlashCommand.msg:
          final gap = argument.indexOf(' ');
          if (gap == -1) return usage();
          final target = argument.substring(0, gap);
          // Saying something to someone is deciding about them, exactly as
          // `/query` is. Without this, messaging a blocked nick would send
          // fine and their reply would vanish.
          if (!_looksLikeChannel(target)) {
            settings.accept(profileId, target);
          }
          await core.sendMessage(
            id: connectionId,
            target: target,
            text: argument.substring(gap + 1),
          );
        case SlashCommand.query:
          if (argument.isEmpty) return usage();
          // A nick, not a channel: `/query #chat` is someone reaching for
          // `/join` and would otherwise open a conversation with a channel
          // name, which the server would answer by ignoring us.
          final nick = argument.split(' ').first;
          if (_looksLikeChannel(nick)) {
            return '$nick is a channel — use /join';
          }
          openDirect(nick);
      }
    } catch (e) {
      return '$e';
    }
    return null;
  }
}
