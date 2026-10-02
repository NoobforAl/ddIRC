import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/chat_state.dart';
import '../model/history.dart';
import '../model/marks.dart';
import '../model/profile.dart';
import '../model/media.dart';
import '../model/notice.dart';
import '../model/people.dart';
import '../model/session.dart';
import '../model/transfer.dart';
import '../model/settings.dart';
import '../model/workspace.dart';
import '../rust/api/store.dart' as store;
import '../rust/api/types.dart' hide TextSpan;
import '../theme.dart';
import 'channel_list.dart';
import 'connection_log_dialog.dart';
import 'conversation_tabs.dart';
import 'layout.dart';
import 'member_list.dart';
import 'menu.dart';
import 'message_view.dart';
import 'motion.dart';
import 'settings/settings_chrome.dart';
import 'notice_bar.dart';
import 'person_sheet.dart';
import 'saved_messages_dialog.dart';
import 'send_file_sheet.dart';
import 'touchable.dart';
import 'transfer_bar.dart';
import 'settings/app_settings_dialog.dart';
import 'settings/channel_browser_dialog.dart';
import 'settings/channel_settings_dialog.dart';
import 'settings/profile_editor_dialog.dart';
import 'settings/server_settings_dialog.dart';

const _channelPanelWidth = 210.0;
const _memberPanelWidth = 190.0;

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.session, this.rail});

  final SessionModel session;

  /// The network rail, when the screen is too narrow for it to stand beside
  /// the conversation and it has to share the channel drawer instead.
  ///
  /// Handed down rather than built here because the workspace owns it: it
  /// lists every network, including the ones this session is not.
  final Widget? rail;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final _composer = TextEditingController();
  final _composerFocus = FocusNode();
  final _scaffold = GlobalKey<ScaffoldState>();

  /// Which suggestion the keyboard is on. Always a valid index into the
  /// current matches, because the list is recomputed on every keystroke.
  int _highlighted = 0;

  /// Escape hides the list without clearing what has been typed. Reset as soon
  /// as the text changes, so it dismisses this attempt and not the next one.
  bool _dismissed = false;

  /// Bumped when the command suggestions change, and listened to by the strip
  /// that draws them and by nothing else.
  ///
  /// Typing used to `setState` the whole screen. Everything on it — the
  /// channel list, the tab strip, the member list, the entire scrollback —
  /// was rebuilt on each keystroke to decide whether to offer `/join`, and on
  /// a low-end phone that is the difference between a composer that keeps up
  /// with a thumb and one that does not. Nothing else here reads what is in
  /// the composer, so nothing else needs telling.
  final _suggestionRevision = ValueNotifier<int>(0);

  /// The line the next message answers, and the conversation it is in. The
  /// conversation is kept alongside so that switching away quietly drops a
  /// reply meant for somewhere else instead of sending it here.
  ///
  /// [excerpt] is set when only part of the line is being answered — "reply
  /// with quote" on a selection — and is what the quote then carries.
  ({String conversation, ChatLine line, String? excerpt})? _replying;

  /// Replies started in other conversations and left there, by conversation
  /// key, so coming back finds the half-written answer still answering.
  final Map<String, ({ChatLine line, String? excerpt})> _parkedReplies = {};

  /// Which conversation the composer's text belongs to. When the active one
  /// changes, what is typed is put away under this name and the new one's
  /// draft brought out — the way a messenger keeps a draft per chat.
  String? _draftFor;

  final _view = MessageViewController();

  /// The search bar, when open: what is typed, the matches in the
  /// scrollback (oldest first), and which of them is showing.
  bool _searching = false;
  final _searchField = TextEditingController();
  final _searchFocus = FocusNode();
  List<ChatLine> _matches = const [];
  int _match = -1;

  /// Matches from saved history, older than anything in the scrollback.
  List<HistoryHit> _older = const [];
  Timer? _searchDebounce;

  /// Which pin the pinned bar is showing, counted from the newest.
  int _pin = 0;

  SessionModel get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_onChanged);
    // What the user wrote about people is drawn on every nick, so an edit
    // has to reach the scrollback and the roster the same way a message does.
    People.instance.addListener(_onChanged);
    // Pins come and go from the message menu, and the bar above the
    // scrollback shows them; history turning on or off changes what the menu
    // and the header can offer.
    Marks.instance.addListener(_onChanged);
    MessageHistory.instance.addListener(_onChanged);
    _draftFor = session.active?.name;
    _restoreDraft(session.active);
    _composer.addListener(_onTyped);
    // On the focus node rather than an ancestor Shortcuts: the focused node is
    // asked first, so arrows and Enter can be claimed for the list before the
    // text field treats them as caret movement and submission.
    _composerFocus.onKeyEvent = _onComposerKey;
  }

  /// The commands matching what has been typed so far.
  ///
  /// Empty unless the composer holds a bare `/word` — once there is a space
  /// the user is writing arguments, and a list of commands is in the way.
  List<SlashCommand> get _suggestions {
    if (_dismissed) return const [];
    final text = _composer.text;
    if (!text.startsWith('/') || text.contains(' ')) return const [];
    return SlashCommand.matching(text.substring(1));
  }

  void _onTyped() {
    if (!mounted) return;
    _dismissed = false;
    _highlighted = 0;
    _redrawSuggestions();
    // Kept as it is typed, not only when the conversation changes: Android
    // can end the process without warning, and a draft that only survived a
    // deliberate switch was a draft that lived on luck. The write waits out a
    // short pause, and nothing on screen is redrawn for it — the list shows
    // drafts only for conversations that are not open.
    final name = _draftFor;
    if (name != null) {
      final replying = _replying;
      ConversationStates.instance.setDraft(
        session.profileId,
        name,
        _composer.text,
        // Only a reply begun here: mid-switch, the composer is refilled
        // before the previous conversation's reply has been put away.
        replyMsgid: replying != null && replying.conversation == name
            ? replying.line.message?.msgid
            : null,
        notify: false,
      );
    }
  }

  /// Redraw the suggestion strip, and only it.
  void _redrawSuggestions() => _suggestionRevision.value++;

  void _complete(SlashCommand command) {
    // The trailing space is the point: completing a command leaves the caret
    // where its argument goes, not butted against the name.
    _composer.value = TextEditingValue(
      text: '/${command.name} ',
      selection: TextSelection.collapsed(offset: command.name.length + 2),
    );
    _dismissed = false;
    _redrawSuggestions();
    _composerFocus.requestFocus();
  }

  KeyEventResult _onComposerKey(FocusNode node, KeyEvent event) {
    // Escape backs out of a reply before it does anything else: it is the
    // most recent thing the user chose, so it is the first thing to undo.
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        _suggestions.isEmpty &&
        _replying != null) {
      setState(() => _replying = null);
      return KeyEventResult.handled;
    }
    final matches = _suggestions;
    if (matches.isEmpty || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _highlighted = (_highlighted + 1) % matches.length;
      _redrawSuggestions();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _highlighted = (_highlighted - 1 + matches.length) % matches.length;
      _redrawSuggestions();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.tab || key == LogicalKeyboardKey.enter) {
      // Enter completes rather than sends. What is in the composer is a bare
      // command name with no argument, which sending would only reject.
      _complete(matches[_highlighted.clamp(0, matches.length - 1)]);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _dismissed = true;
      _redrawSuggestions();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    // Leaving the network is leaving its conversation too: what was typed
    // goes with it, to be there when it is opened again.
    _parkDraft(_draftFor, tearingDown: true);
    session.removeListener(_onChanged);
    People.instance.removeListener(_onChanged);
    Marks.instance.removeListener(_onChanged);
    MessageHistory.instance.removeListener(_onChanged);
    _composer.removeListener(_onTyped);
    _composerFocus.onKeyEvent = null;
    _composer.dispose();
    _composerFocus.dispose();
    _suggestionRevision.dispose();
    _searchField.dispose();
    _searchFocus.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onChanged() {
    if (!mounted) return;
    final now = session.active?.name;
    if (now != _draftFor) _switchedTo(session.active);
    setState(() {});
  }

  /// The conversation on screen changed: put away what was typed for the old
  /// one, bring out what was typed for the new one, and close a search that
  /// was about the old one.
  void _switchedTo(Conversation? next) {
    _parkDraft(_draftFor);
    _draftFor = next?.name;
    _restoreDraft(next);
    _pin = 0;
    if (_searching) _closeSearch();
  }

  /// Keep what is in the composer, and the reply it is part of, under
  /// [name].
  void _parkDraft(String? name, {bool tearingDown = false}) {
    if (name == null) return;
    final key = name.toLowerCase();
    final replying = _replying;
    if (replying != null && replying.conversation == name) {
      _parkedReplies[key] = (line: replying.line, excerpt: replying.excerpt);
    } else {
      _parkedReplies.remove(key);
    }
    ConversationStates.instance.setDraft(
      session.profileId,
      name,
      _composer.text,
      replyMsgid: replying?.line.message?.msgid,
      notify: !tearingDown,
    );
  }

  /// Bring out what was typed for [conversation], if anything.
  void _restoreDraft(Conversation? conversation) {
    final text = conversation == null
        ? null
        : ConversationStates.instance.draftOf(
            session.profileId,
            conversation.name,
          );
    _composer.value = text == null
        ? TextEditingValue.empty
        : TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
    _replying = null;
    if (conversation == null) return;
    final parked = _parkedReplies[conversation.name.toLowerCase()];
    if (parked != null) {
      _replying = (
        conversation: conversation.name,
        line: parked.line,
        excerpt: parked.excerpt,
      );
      return;
    }
    // A draft from a previous run knows only the id of what it answered;
    // the line is found again if it is still in the scrollback.
    final msgid = ConversationStates.instance
        .of(session.profileId, conversation.name)
        ?.draftReplyMsgid;
    if (msgid == null) return;
    for (final line in conversation.lines.reversed) {
      if (line.message?.msgid == msgid) {
        _replying = (
          conversation: conversation.name,
          line: line,
          excerpt: null,
        );
        return;
      }
    }
  }

  /// Who someone is: what the server says, what you wrote about them, and
  /// what you can do about them.
  void _showPerson(String nick) {
    PersonSheet.show(context, session: session, nick: nick);
  }

  /// Reply to [line]: remember it, show it above the composer, and put the
  /// caret where the answer goes.
  void _replyTo(ChatLine line) {
    final active = session.active;
    if (active == null || line.message == null) return;
    setState(
      () => _replying = (conversation: active.name, line: line, excerpt: null),
    );
    _composerFocus.requestFocus();
  }

  /// Reply to [line], quoting only [excerpt] of it — what was selected.
  void _quote(ChatLine line, String excerpt) {
    final active = session.active;
    if (active == null || line.message == null) return;
    setState(
      () =>
          _replying = (conversation: active.name, line: line, excerpt: excerpt),
    );
    _composerFocus.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // Search
  // ---------------------------------------------------------------------------

  void _openSearch() {
    if (session.active == null) return;
    setState(() => _searching = true);
    _searchFocus.requestFocus();
    _searchField.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _searchField.text.length,
    );
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searching = false;
      _matches = const [];
      _match = -1;
      _older = const [];
    });
  }

  /// Find [query] in what is in the scrollback now, at once, and — with
  /// history on — in what is saved further back, a moment later.
  void _search(String query) {
    final active = session.active;
    final needle = query.trim().toLowerCase();
    if (active == null || needle.isEmpty) {
      setState(() {
        _matches = const [];
        _match = -1;
        _older = const [];
      });
      return;
    }
    final matches = [
      for (final line in active.lines)
        if (line.message case final message?)
          if (message.spans
              .map((s) => s.text)
              .join()
              .toLowerCase()
              .contains(needle))
            line,
    ];
    setState(() {
      _matches = matches;
      _match = matches.length - 1;
    });
    if (matches.isNotEmpty) _view.reveal(matches.last);

    _searchDebounce?.cancel();
    if (!MessageHistory.instance.enabled) return;
    _searchDebounce = Timer(const Duration(milliseconds: 250), () async {
      final hits = await MessageHistory.instance.search(
        profileId: session.profileId,
        conversation: active.name,
        query: query,
        limit: 30,
      );
      if (!mounted || _searchField.text != query) return;
      // Only what the scrollback no longer holds; the rest is already in
      // the arrows above.
      final oldest = active.lines.isEmpty ? null : active.lines.first.at;
      setState(() {
        _older = [
          for (final hit in hits)
            if (oldest == null || hit.line.at.isBefore(oldest)) hit,
        ];
      });
    });
  }

  /// Step through the matches: back is older, forward is newer.
  void _step(int by) {
    if (_matches.isEmpty) return;
    setState(() {
      _match = (_match + by).clamp(0, _matches.length - 1);
    });
    _view.reveal(_matches[_match]);
  }

  /// Open the scrollback at a line from further back than it reaches.
  Future<void> _openOlder(ChatLine target) async {
    final active = session.active;
    if (active == null) return;
    final reached = await session.reachBack(active, target.at);
    if (!mounted) return;
    final line = _findLine(active, target);
    if (!reached || line == null) {
      _say('That is too far back to show in place.');
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    await _view.reveal(line);
  }

  /// The line in [conversation] that is [like] — the same moment, the same
  /// person, the same words — whatever object it is now.
  static ChatLine? _findLine(Conversation conversation, ChatLine like) {
    final message = like.message;
    if (message == null) return null;
    final at = like.at.millisecondsSinceEpoch;
    final text = Marks.plainText(message.spans);
    for (final line in conversation.lines.reversed) {
      final m = line.message;
      if (m != null &&
          line.at.millisecondsSinceEpoch == at &&
          m.sender == message.sender &&
          Marks.plainText(m.spans) == text) {
        return line;
      }
    }
    return null;
  }

  void _say(String text) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
  );

  // ---------------------------------------------------------------------------
  // Pins and saved messages
  // ---------------------------------------------------------------------------

  /// Go to a pinned or saved message, in this network.
  Future<void> _openMark(store.Mark mark) async {
    if (mark.profileId != session.profileId) return;
    final conversation = session.conversations
        .where((c) => MessageHistory.key(c.name) == mark.conversation)
        .firstOrNull;
    if (conversation == null) {
      _say('You are not in ${mark.conversation} right now.');
      return;
    }
    if (session.active != conversation) session.select(conversation.name);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final like = Marks.lineOf(mark);
    final here = _findLine(conversation, like);
    if (here != null) {
      await _view.reveal(here);
    } else {
      await _openOlder(like);
    }
  }

  /// The pinned bar was tapped: go to the pin it shows, then show the one
  /// before it, the way a messenger cycles through a chat's pins.
  void _cyclePins(List<store.Mark> pins) {
    if (pins.isEmpty) return;
    final index = _pin.clamp(0, pins.length - 1);
    _openMark(pins[pins.length - 1 - index]);
    setState(() => _pin = (index + 1) % pins.length);
  }

  void _openSaved() {
    SavedMessagesDialog.show(
      context,
      profileId: session.profileId,
      onOpen: _openMark,
    );
  }

  /// Address [nick]: their name at the start of the composer, the IRC way,
  /// with the caret after it. Replaces a name already there rather than
  /// stacking a second one in front of it.
  void _mention(String nick) {
    final text = _composer.text.replaceFirst(RegExp(r'^[^\s:]+: '), '');
    final value = '$nick: $text';
    _composer.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _composerFocus.requestFocus();
  }

  /// The reply the composer is holding, if it is for the conversation on
  /// screen.
  ChatLine? get _replyLine {
    final replying = _replying;
    if (replying == null || replying.conversation != session.active?.name) {
      return null;
    }
    return replying.line;
  }

  Future<void> _submit() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    final message = _replyLine?.message;
    final excerpt = _replying?.excerpt;
    if (_replying != null) setState(() => _replying = null);
    // Sent is no longer a draft, here or on disk.
    final active = session.active;
    if (active != null) {
      _parkedReplies.remove(active.name.toLowerCase());
      ConversationStates.instance.setDraft(session.profileId, active.name, '');
    }
    final error = await session.submit(
      text,
      replyTo: message == null
          ? null
          : ReplyRef(
              msgid: message.msgid,
              nick: message.sender,
              excerpt: excerpt ?? message.spans.map((s) => s.text).join(),
            ),
    );
    if (!mounted) return;
    // A rejected command is the user's own typing coming back at them, so it
    // is an error rather than a warning — but it still goes through the
    // classifier, because `submit` also relays failures from the core.
    session.raiseNotice(error == null ? null : noticeForFailure(error));
    // Keep the caret where the user is typing — losing focus after a command
    // means reaching for the mouse to say the next thing.
    _composerFocus.requestFocus();
  }

  void _select(String name) {
    session.select(name);
    // Picking a channel out of the drawer is the end of that errand, so the
    // drawer closes onto what was chosen. Nothing to close when it is pinned.
    if (!context.layout.channelsPinned) Navigator.of(context).maybePop();
  }

  /// Open a conversation with someone in the roster.
  ///
  /// The member panel is a drawer on a narrow screen, and it closes for the
  /// same reason the channel drawer does: picking a name is the end of that
  /// errand, and a panel left open would cover the conversation it just
  /// opened.
  void _openDirect(String nick) {
    session.openDirect(nick);
    if (!context.layout.membersPinned) Navigator.of(context).maybePop();
  }

  /// Open the server's directory of channels.
  ///
  /// Closes the channel drawer on the way, on a narrow screen: the dialog
  /// covers it anyway, and leaving it open behind would mean coming back to
  /// two things stacked over the conversation.
  void _browseChannels() {
    if (!context.layout.channelsPinned) Navigator.of(context).maybePop();
    ChannelBrowserDialog.show(context, session);
  }

  /// Whether the member list is currently sitting beside the conversation.
  ///
  /// Two conditions, and both are needed: the window has to be wide enough to
  /// hold it, and the user has to have asked for it. It used to be the first
  /// alone, which made a roster of people who are mostly silent a property of
  /// the window size rather than of anything anyone wanted.
  bool get _membersBeside =>
      context.layout.membersPinned && SettingsScope.of(context).showMembers;

  /// The member button, which does different things at different widths.
  ///
  /// Wide enough for the panel, it turns the panel on and off. Narrower, there
  /// is no panel to turn on and it opens the drawer instead. One control
  /// either way, because from the user's side it is one question — show me who
  /// is here — and where the answer appears is the app's problem.
  void _toggleMembers() {
    final settings = SettingsScope.of(context);
    if (context.layout.membersPinned) {
      settings.showMembers = !settings.showMembers;
    } else {
      _scaffold.currentState?.openEndDrawer();
    }
  }

  /// Pick a file and offer it to whoever this conversation is with.
  ///
  /// Four steps, and the order matters: pick, clean, confirm, send. The
  /// cleaning happens before the confirmation so that the dialog can say what
  /// was actually taken out of *this* file rather than what the setting
  /// promises in general.
  Future<void> _attachFile() async {
    final conversation = session.active;
    if (conversation == null) return;

    final picked = await openFile();
    if (picked == null || !mounted) return;

    final cleaner = MediaCleaner(SettingsScope.of(context));
    final prepared = await prepareForSending(cleaner, picked.path);
    if (!mounted) return;
    if (prepared == null) {
      session.raiseNotice(
        const Notice.error(
          'Could not read that file',
          detail: 'It may have moved, or be open in another program.',
        ),
      );
      return;
    }

    final agreed = await SendFileSheet.ask(
      context,
      filename: picked.name,
      target: conversation.name,
      cleaned: prepared.cleaned,
      sizeBytes: prepared.size,
    );
    if (!agreed || !mounted) return;

    final error = await session.sendFile(conversation.name, prepared.path);
    if (!mounted) return;
    session.raiseNotice(error == null ? null : noticeForFailure(error));
  }

  /// Take up an offer, into the app's own received-files directory.
  ///
  /// Not the system Downloads folder — see `receivedFilesDirectory`. A file
  /// somebody else chose does not belong among the ones the user fetched
  /// themselves.
  Future<void> _acceptTransfer(FileTransfer transfer) async {
    final String directory;
    try {
      directory = (await receivedFilesDirectory()).path;
    } catch (e) {
      if (!mounted) return;
      session.raiseNotice(Notice.error('Nowhere to save it', detail: '$e'));
      return;
    }
    if (!mounted) return;
    final error = await session.acceptTransfer(transfer.id, directory);
    if (!mounted) return;
    session.raiseNotice(error == null ? null : noticeForFailure(error));
  }

  /// Give up on the current attempt and dial again immediately.
  Future<void> _retry() async {
    final profile = ProfileScope.of(context).byId(session.profileId);
    if (profile == null) return;
    await WorkspaceScope.of(context).reconnect(profile);
  }

  void _disconnect() {
    // The workspace owns the connection's lifetime; there is no route to pop,
    // because other networks may still be up behind this one.
    WorkspaceScope.of(context).disconnect(session.profileId);
  }

  void _openChannelSettings([Conversation? conversation]) {
    final target = conversation ?? session.active;
    if (target == null) return;
    ChannelSettingsDialog.show(context, session: session, conversation: target);
  }

  void _openServerSettings() =>
      ServerSettingsDialog.show(context, session: session);

  void _openAppSettings() => AppSettingsDialog.show(context);

  /// What this connection has actually been doing, in full.
  void _openConnectionLog() =>
      ConnectionLogDialog.show(context, session: session);

  void _openNetworkEditor() {
    final profile = ProfileScope.of(context).byId(session.profileId);
    if (profile == null) return;
    ProfileEditorDialog.show(context, profile: profile);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final layout = context.layout;
    final screenWidth = MediaQuery.sizeOf(context).width;
    final active = session.active;

    final channels = ChannelList(
      session: session,
      networkName:
          ProfileScope.of(context).byId(session.profileId)?.name ?? 'ddIRC',
      onSelect: _select,
      onBrowse: _browseChannels,
      onDisconnect: _disconnect,
      onChannelSettings: _openChannelSettings,
    );
    final members = active == null
        ? const SizedBox.shrink()
        : MemberList(
            members: active.members,
            colorNicks: SettingsScope.of(context).colorNicks,
            self: session.nick,
            // Closable either way. Beside the conversation the cross puts the
            // setting back; in a drawer it dismisses the drawer. A panel the
            // user turned on and cannot turn off from where they are looking
            // at it is the reason it was always on in the first place.
            onClose: layout.membersPinned
                ? () => SettingsScope.of(context).showMembers = false
                : () => Navigator.of(context).maybePop(),
            onOpenDirect: _openDirect,
            profileId: session.profileId,
            onEditPerson: _showPerson,
          );

    return Scaffold(
      key: _scaffold,
      // Networks and channels answer the same question — where am I — so on a
      // narrow screen they are one drawer behind one button rather than two
      // competing for an edge each.
      drawer: layout.channelsPinned
          ? null
          : Drawer(
              width: Layout.drawerWidth(screenWidth, preferred: 300),
              child: SafeArea(
                child: Row(
                  children: [
                    if (widget.rail != null) widget.rail!,
                    Expanded(child: channels),
                  ],
                ),
              ),
            ),
      endDrawer: layout.membersPinned || active == null || !active.isChannel
          ? null
          : Drawer(
              width: Layout.drawerWidth(screenWidth, preferred: 260),
              child: SafeArea(child: members),
            ),
      body: SafeArea(
        child: Row(
          children: [
            if (layout.channelsPinned)
              SizedBox(
                width: _channelPanelWidth,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      right: BorderSide(color: t.rule, width: Tokens.hairline),
                    ),
                  ),
                  child: channels,
                ),
              ),
            Expanded(child: _conversationPane(t, layout, active)),
            if (_membersBeside && active != null && active.isChannel)
              SizedBox(
                width: _memberPanelWidth,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(color: t.rule, width: Tokens.hairline),
                    ),
                  ),
                  child: members,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _conversationPane(Tokens t, Layout layout, Conversation? active) {
    final topic = active?.topic;
    final pins = active == null
        ? const <store.Mark>[]
        : Marks.instance.pinsFor(session.profileId, active.name);
    // Ctrl+F, or Cmd+F — wherever focus is in the conversation, the composer
    // included, which is where it nearly always is.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _openSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openSearch,
      },
      child: Column(
        children: [
          _Header(
            session: session,
            conversation: active,
            layout: layout,
            onOpenChannels: () => _scaffold.currentState?.openDrawer(),
            onOpenMembers: _toggleMembers,
            membersOpen: _membersBeside,
            onChannelSettings: _openChannelSettings,
            onServerSettings: _openServerSettings,
            onNetworkEditor: _openNetworkEditor,
            onAppSettings: _openAppSettings,
            onConnectionLog: _openConnectionLog,
            onSearch: _openSearch,
            onSaved: _openSaved,
          ),
          // Anything other than "connected" gets a bar of its own. The status
          // dot in the header can say something is wrong, but it has nowhere to
          // put the reason, the countdown, or a way to stop waiting.
          _ConnectionBar(
            status: session.status,
            detail: session.statusDetail,
            onRetry: _retry,
            onViewLog: _openConnectionLog,
          ),
          ConversationTabs(
            session: session,
            onSelect: session.select,
            onClose: session.closeTab,
          ),
          // A topic arriving, or switching to a channel that has none, moves
          // the whole scrollback. Unrolling it says which way everything went.
          Reveal(
            child: _searching
                ? _SearchBar(
                    controller: _searchField,
                    focusNode: _searchFocus,
                    matches: _matches.length,
                    current: _match,
                    older: _older,
                    onChanged: _search,
                    onOlder: () => _step(-1),
                    onNewer: () => _step(1),
                    onClose: _closeSearch,
                    onOpenOlder: (hit) => _openOlder(hit.line),
                  )
                : topic == null
                ? null
                : _TopicBar(topic: topic),
          ),
          Reveal(
            child: pins.isEmpty || _searching
                ? null
                : _PinnedBar(
                    pins: pins,
                    showing: _pin.clamp(0, pins.length - 1),
                    onTap: () => _cyclePins(pins),
                    onOpen: _openMark,
                  ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              // Fast, and a fade with nothing sliding: a wall of text in motion
              // is unreadable for as long as the transition lasts.
              duration: context.motion.fast,
              child: active == null
                  ? Center(
                      key: const ValueKey('no-channel'),
                      child: Text(
                        'Not in a channel yet.\nUse /join #channel below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: t.faint,
                          fontSize: 13,
                          height: 1.6,
                        ),
                      ),
                    )
                  : MessageView(
                      // Rebuild the scroll state when switching conversations
                      // — and once more if a "new messages" rule is placed
                      // after it was built, which the view only reads then.
                      key: ValueKey('${active.name}/${active.markerEpoch}'),
                      conversation: active,
                      profileId: session.profileId,
                      controller: _view,
                      highlight: _searching ? _searchField.text : null,
                      onPersonTap: _showPerson,
                      onReply: active.pending ? null : _replyTo,
                      onQuote: active.pending ? null : _quote,
                      onMention: active.pending ? null : _mention,
                      onLoadOlder: () => session.loadOlder(active),
                    ),
            ),
          ),
          // Offers and transfers in flight, between the scrollback and the
          // composer. Revealed rather than appearing, so a transfer starting
          // does not shove the composer out from under a caret mid-word.
          Reveal(
            child: active == null || active.transfers.isEmpty
                ? null
                : TransferBar(
                    session: session,
                    conversation: active,
                    onAccept: _acceptTransfer,
                  ),
          ),
          // Growing rather than appearing, so a notice never shoves the
          // composer out from under a caret already being typed into.
          NoticeReveal(
            notice: session.notice,
            onDismiss: session.dismissNotice,
          ),
          ListenableBuilder(
            listenable: _suggestionRevision,
            builder: (context, _) => _CommandSuggestions(
              commands: _suggestions,
              highlighted: _highlighted,
              onPick: _complete,
            ),
          ),
          Reveal(
            child: _replyLine == null
                ? null
                : _ReplyStrip(
                    line: _replyLine!,
                    excerpt: _replying?.excerpt,
                    onCancel: () => setState(() => _replying = null),
                  ),
          ),
          _composerBar(t, active),
        ],
      ),
    );
  }

  Widget _composerBar(Tokens t, Conversation? active) {
    final g = context.layout.gutter;
    // A request is answered, not replied to. Until it is accepted the composer
    // is not a composer, because sending anything — even a refusal — tells
    // whoever sent it that somebody is here, which is most of what an
    // unsolicited message is fishing for.
    if (active != null && active.pending) {
      return _RequestBar(
        nick: active.name,
        onAccept: () => session.acceptDirect(active.name),
        onDecline: () => session.declineDirect(active.name),
      );
    }
    return Container(
      padding: EdgeInsets.fromLTRB(g - 4, 8, g - 8, 10),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          top: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _composer,
              focusNode: _composerFocus,
              onSubmitted: (_) => _submit(),
              textInputAction: TextInputAction.send,
              maxLines: 4,
              minLines: 1,
              autocorrect: false,
              style: TextStyle(color: t.text, fontSize: 14),
              decoration: InputDecoration(
                // The hint always explains the state, so a composer that
                // cannot send never looks simply broken.
                hintText: active == null
                    ? 'Join a channel to talk — try /join #channel'
                    : 'Message ${active.name}',
                hintStyle: TextStyle(color: t.faint, fontSize: 14),
                isDense: true,
                filled: true,
                fillColor: t.bubble,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                enabledBorder: _border(t.rule, Tokens.hairline),
                focusedBorder: _border(t.accent.withValues(alpha: 0.7), 1),
              ),
            ),
          ),
          // Only where there is somewhere to send it, and only when the
          // setting is on. A button that opens a picker and then explains that
          // the feature is off is a button that wasted the user's time.
          if (active != null && SettingsScope.of(context).fileTransfers)
            IconButton(
              onPressed: _attachFile,
              icon: const Icon(Icons.attach_file, size: 19),
              color: t.muted,
              tooltip: 'Send a file',
            ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 1),
            child: IconButton.filled(
              onPressed: _submit,
              icon: const Icon(Icons.arrow_upward_rounded, size: 20),
              style: IconButton.styleFrom(
                backgroundColor: t.accent,
                foregroundColor: t.onAccent,
                fixedSize: const Size(42, 42),
              ),
              tooltip: 'Send',
            ),
          ),
        ],
      ),
    );
  }

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Tokens.radiusXL),
        borderSide: BorderSide(color: color, width: width),
      );
}

/// What the next message will answer, above the composer, with a way out.
class _ReplyStrip extends StatelessWidget {
  const _ReplyStrip({required this.line, required this.onCancel, this.excerpt});

  final ChatLine line;
  final VoidCallback onCancel;

  /// The part of [line] being quoted, when it is not all of it.
  final String? excerpt;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final message = line.message!;
    final g = context.layout.gutter;
    return Container(
      padding: EdgeInsets.fromLTRB(g, 8, g - 12, 6),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          top: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.reply_rounded, size: 18, color: t.accent),
          const SizedBox(width: 10),
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: t.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to ${message.isSelf ? 'yourself' : message.sender}',
                  style: TextStyle(
                    color: t.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  excerpt == null
                      ? message.spans.map((s) => s.text).join()
                      : '“$excerpt”',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: t.muted, fontSize: 12.5),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: t.muted,
            tooltip: 'Cancel reply',
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.session,
    required this.conversation,
    required this.layout,
    required this.onOpenChannels,
    required this.onOpenMembers,
    required this.membersOpen,
    required this.onChannelSettings,
    required this.onServerSettings,
    required this.onNetworkEditor,
    required this.onAppSettings,
    required this.onConnectionLog,
    required this.onSearch,
    required this.onSaved,
  });

  final SessionModel session;
  final Conversation? conversation;
  final VoidCallback onSearch;
  final VoidCallback onSaved;
  final Layout layout;
  final VoidCallback onOpenChannels;
  final VoidCallback onOpenMembers;

  /// Whether the member list is currently beside the conversation, so the
  /// button can show it as pressed rather than leaving the user to work out
  /// which of the two states they are in.
  final bool membersOpen;
  final VoidCallback onChannelSettings;
  final VoidCallback onServerSettings;
  final VoidCallback onNetworkEditor;
  final VoidCallback onAppSettings;
  final VoidCallback onConnectionLog;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final unread = session.totalUnread;

    return Container(
      // The gutter is the text's left edge everywhere in this column, so the
      // conversation's name lines up with the messages under it. When the
      // channel button is here instead, its own padding does that job.
      padding: EdgeInsets.fromLTRB(
        layout.channelsPinned ? layout.gutter : 4,
        8,
        8,
        8,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        children: [
          if (!layout.channelsPinned)
            Stack(
              alignment: Alignment.topRight,
              children: [
                IconButton(
                  onPressed: onOpenChannels,
                  icon: const Icon(Icons.menu, size: 20),
                  color: t.muted,
                  tooltip: 'Channels',
                ),
                if (unread > 0)
                  Padding(
                    padding: EdgeInsets.only(top: 8, right: 8),
                    child: _Dot(color: t.accent, size: 6),
                  ),
              ],
            ),
          _StatusDot(status: session.status),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              conversation?.name ?? session.nick,
              style: TextStyle(
                color: t.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (conversation != null && conversation!.isChannel)
            // Always a button, at every width. It used to be a bare number
            // once the list was beside us, on the grounds that the panel was
            // already there and nothing needed reaching — which stopped being
            // true the moment the panel became something to ask for.
            //
            // The count is on the button either way, because who is present is
            // worth knowing at a glance whether or not the list is open.
            TextButton.icon(
              onPressed: onOpenMembers,
              icon: Icon(
                membersOpen ? Icons.people : Icons.people_outline,
                size: 17,
              ),
              label: Text('${conversation!.members.length}'),
              style: TextButton.styleFrom(
                foregroundColor: membersOpen ? t.accent : t.muted,
                visualDensity: VisualDensity.compact,
              ),
            ),
          _SettingsMenu(
            hasChannel: conversation != null,
            channelName: conversation?.name,
            onChannelSettings: onChannelSettings,
            onServerSettings: onServerSettings,
            onNetworkEditor: onNetworkEditor,
            onAppSettings: onAppSettings,
            onConnectionLog: onConnectionLog,
            onSearch: onSearch,
            onSaved: onSaved,
          ),
        ],
      ),
    );
  }
}

/// The one place every settings dialog can be reached from.
enum _SettingsTarget {
  search,
  saved,
  channel,
  server,
  network,
  app,
  connectionLog,
}

class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({
    required this.hasChannel,
    required this.channelName,
    required this.onChannelSettings,
    required this.onServerSettings,
    required this.onNetworkEditor,
    required this.onAppSettings,
    required this.onConnectionLog,
    required this.onSearch,
    required this.onSaved,
  });

  final VoidCallback onSearch;
  final VoidCallback onSaved;
  final bool hasChannel;
  final String? channelName;
  final VoidCallback onChannelSettings;
  final VoidCallback onServerSettings;
  final VoidCallback onNetworkEditor;
  final VoidCallback onAppSettings;

  /// The way back to the connection log once the bar that offers it has gone.
  ///
  /// The bar only exists while something is wrong, and "why did it take so
  /// long to connect" is a question asked after it has finally worked.
  final VoidCallback onConnectionLog;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return PopupMenuButton<_SettingsTarget>(
      icon: const Icon(Icons.tune, size: 18),
      color: t.surface,
      elevation: 0,
      tooltip: 'Settings',
      position: PopupMenuPosition.under,
      shape: menuShape(t),
      onSelected: (target) => switch (target) {
        _SettingsTarget.search => onSearch(),
        _SettingsTarget.saved => onSaved(),
        _SettingsTarget.channel => onChannelSettings(),
        _SettingsTarget.server => onServerSettings(),
        _SettingsTarget.network => onNetworkEditor(),
        _SettingsTarget.app => onAppSettings(),
        _SettingsTarget.connectionLog => onConnectionLog(),
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: _SettingsTarget.search,
          enabled: hasChannel,
          child: MenuRow(
            icon: Icons.search_rounded,
            label: 'Search in conversation',
            enabled: hasChannel,
          ),
        ),
        PopupMenuItem(
          value: _SettingsTarget.saved,
          // Disabled rather than hidden, like the channel entry below, with
          // the reason in the label.
          enabled: MessageHistory.instance.enabled,
          child: MenuRow(
            icon: Icons.bookmarks_outlined,
            label: MessageHistory.instance.enabled
                ? 'Saved messages'
                : 'Saved messages — needs message history',
            enabled: MessageHistory.instance.enabled,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _SettingsTarget.channel,
          // Disabled rather than hidden, so the menu never changes shape and
          // the reason is legible: there is no channel to configure.
          enabled: hasChannel,
          child: MenuRow(
            icon: Icons.tag,
            label: channelName == null
                ? 'Channel settings'
                : 'Channel settings — $channelName',
            enabled: hasChannel,
          ),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.server,
          child: MenuRow(icon: Icons.dns_outlined, label: 'Server settings'),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.network,
          child: MenuRow(
            icon: Icons.edit_outlined,
            label: 'Edit this network…',
          ),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.connectionLog,
          child: MenuRow(
            icon: Icons.receipt_long_outlined,
            label: 'Connection log…',
          ),
        ),
        const PopupMenuItem(
          value: _SettingsTarget.app,
          child: MenuRow(icon: Icons.settings_outlined, label: 'App settings'),
        ),
      ],
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.status});

  final ConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // The third field is whether the client is still waiting on the server.
    // Amber alone cannot say that — connecting and reconnecting look exactly
    // like a settled state until the dot moves.
    final (color, label, waiting) = switch (status) {
      ConnectionStatus_Connected() => (t.ok, 'Connected', false),
      ConnectionStatus_Connecting() => (t.warn, 'Connecting', true),
      ConnectionStatus_Registering() => (t.warn, 'Registering', true),
      ConnectionStatus_Reconnecting(:final retryInSecs) => (
        t.warn,
        'Reconnecting in ${retryInSecs}s',
        true,
      ),
      ConnectionStatus_Disconnected() => (t.bad, 'Disconnected', false),
    };
    return Tooltip(
      message: label,
      child: Pulse(
        running: waiting,
        child: _Dot(color: color, size: 8),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: context.motion.fast,
      curve: Motion.curve,
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class _TopicBar extends StatelessWidget {
  const _TopicBar({required this.topic});

  final String topic;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(g, 7, g, 8),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Tooltip(
        message: topic,
        child: Text(
          topic,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.muted, fontSize: 12, height: 1.3),
        ),
      ),
    );
  }
}

/// Finding something in the conversation: where the topic was, for as long
/// as it is open.
///
/// The arrows step through what the scrollback holds, newest first, the way
/// every find bar does. What is saved further back — with history on — is
/// listed underneath rather than folded into the count, because reaching it
/// means loading pages the scrollback does not hold, and an arrow press that
/// sometimes took a second would be an arrow that felt broken.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.matches,
    required this.current,
    required this.older,
    required this.onChanged,
    required this.onOlder,
    required this.onNewer,
    required this.onClose,
    required this.onOpenOlder,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final int matches;
  final int current;
  final List<HistoryHit> older;
  final ValueChanged<String> onChanged;
  final VoidCallback onOlder;
  final VoidCallback onNewer;
  final VoidCallback onClose;
  final ValueChanged<HistoryHit> onOpenOlder;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    final settings = SettingsScope.of(context);
    final counter = controller.text.trim().isEmpty
        ? ''
        : matches == 0
        ? 'None here'
        : '${current + 1} of $matches';

    final field = CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onClose,
        const SingleActivator(LogicalKeyboardKey.enter): onOlder,
        const SingleActivator(LogicalKeyboardKey.enter, shift: true): onNewer,
        const SingleActivator(LogicalKeyboardKey.arrowUp): onOlder,
        const SingleActivator(LogicalKeyboardKey.arrowDown): onNewer,
      },
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        autocorrect: false,
        style: TextStyle(color: t.text, fontSize: 13.5),
        textAlignVertical: TextAlignVertical.center,
        decoration: InputDecoration(
          hintText: 'Search this conversation',
          hintStyle: TextStyle(color: t.faint, fontSize: 13.5),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: t.muted),
          isDense: true,
          border: InputBorder.none,
        ),
      ),
    );

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          bottom: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(g - 8, 2, 4, 2),
            child: Row(
              children: [
                Expanded(child: field),
                Text(counter, style: TextStyle(color: t.muted, fontSize: 12)),
                IconButton(
                  onPressed: matches == 0 || current <= 0 ? null : onOlder,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
                  color: t.muted,
                  tooltip: 'Older match',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: matches == 0 || current >= matches - 1
                      ? null
                      : onNewer,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                  color: t.muted,
                  tooltip: 'Newer match',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: t.muted,
                  tooltip: 'Close search',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          if (older.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.fromLTRB(g, 0, g, 8),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Further back',
                      style: TextStyle(
                        color: t.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final hit in older)
                    Touchable(
                      onTap: () => onOpenOlder(hit),
                      borderRadius: BorderRadius.circular(Tokens.radiusS),
                      builder: (context, touch) => Container(
                        color: t.surfaceHover.withValues(alpha: touch.wash),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text:
                                    '${AppSettings.describeDay(hit.line.at)} '
                                    '${settings.formatTime(hit.line.at)}  ',
                                style: TextStyle(color: t.faint),
                              ),
                              TextSpan(
                                text: '${hit.line.message?.sender}: ',
                                style: TextStyle(
                                  color: t.muted,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              TextSpan(
                                text: Marks.plainText(
                                  hit.line.message?.spans ?? const [],
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.text, fontSize: 12.5),
                        ),
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

/// The conversation's pinned messages, one at a time, above the scrollback.
///
/// Tapping it goes to the pin it shows and moves on to the one before, so
/// every pin is a few taps away without opening anything; the list button
/// shows them all at once.
class _PinnedBar extends StatelessWidget {
  const _PinnedBar({
    required this.pins,
    required this.showing,
    required this.onTap,
    required this.onOpen,
  });

  /// Oldest first, as the store keeps them.
  final List<store.Mark> pins;

  /// Which, counted from the newest.
  final int showing;
  final VoidCallback onTap;
  final ValueChanged<store.Mark> onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    final pin = pins[pins.length - 1 - showing];
    return Touchable(
      onTap: onTap,
      builder: (context, touch) => Container(
        width: double.infinity,
        padding: EdgeInsets.fromLTRB(g, 6, 4, 6),
        decoration: BoxDecoration(
          color: Color.alphaBlend(
            t.surfaceHover.withValues(alpha: touch.wash),
            t.surface,
          ),
          border: Border(
            bottom: BorderSide(color: t.rule, width: Tokens.hairline),
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 3,
              height: 30,
              decoration: BoxDecoration(
                color: t.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    pins.length == 1
                        ? 'Pinned message'
                        : 'Pinned message ${pins.length - showing} of '
                              '${pins.length}',
                    style: TextStyle(
                      color: t.accent,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${pin.sender ?? ''}: ${Marks.plainText(pin.spans)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: t.text, fontSize: 12.5),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => _showPinnedList(context, pins, onOpen),
              icon: const Icon(Icons.format_list_bulleted_rounded, size: 18),
              color: t.muted,
              tooltip: 'All pinned messages',
            ),
          ],
        ),
      ),
    );
  }
}

/// Every pin in the conversation, newest first, each with a way to it and a
/// way to unpin it. Follows [Marks] while open, so unpinning one takes it off
/// the list at once.
Future<void> _showPinnedList(
  BuildContext context,
  List<store.Mark> pins,
  ValueChanged<store.Mark> onOpen,
) {
  final first = pins.first;
  return showDialog<void>(
    context: context,
    builder: (_) => ListenableBuilder(
      listenable: Marks.instance,
      builder: (context, _) => _PinnedListBody(
        pins: Marks.instance
            .pinsFor(first.profileId, first.conversation)
            .reversed
            .toList(),
        onOpen: onOpen,
      ),
    ),
  );
}

class _PinnedListBody extends StatelessWidget {
  const _PinnedListBody({required this.pins, required this.onOpen});

  final List<store.Mark> pins;
  final ValueChanged<store.Mark> onOpen;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final settings = SettingsScope.of(context);
    return SettingsDialog(
      title: 'Pinned messages',
      subtitle: pins.isEmpty ? 'Nothing pinned' : '${pins.length} pinned',
      children: [
        if (pins.isEmpty)
          const SettingsNote(text: 'Nothing is pinned here any more.'),
        for (final pin in pins)
          ListTile(
            dense: true,
            title: Text(
              Marks.plainText(pin.spans),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.text, fontSize: 13),
            ),
            subtitle: Text(
              '${pin.sender ?? ''} · '
              '${AppSettings.describeDay(DateTime.fromMillisecondsSinceEpoch(pin.atMs))} '
              '${settings.formatTime(DateTime.fromMillisecondsSinceEpoch(pin.atMs))}',
              style: TextStyle(color: t.muted, fontSize: 11.5),
            ),
            onTap: () {
              Navigator.of(context).pop();
              onOpen(pin);
            },
            trailing: IconButton(
              onPressed: () => Marks.instance.remove(pin),
              icon: const Icon(Icons.push_pin, size: 18),
              color: t.muted,
              tooltip: 'Unpin',
            ),
          ),
      ],
    );
  }
}

/// Command errors show inline above the composer — never as a dialog.
/// Where the composer would be, while a stranger is waiting for an answer.
///
/// In the composer's place rather than above it, because the two are mutually
/// exclusive: there is exactly one thing to do with a conversation you have not
/// accepted, and it is not typing into it. Putting the buttons where the hands
/// already are also means the decision cannot be missed by someone who scrolled
/// past a banner.
class _RequestBar extends StatelessWidget {
  const _RequestBar({
    required this.nick,
    required this.onAccept,
    required this.onDecline,
  });

  final String nick;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    return Container(
      padding: EdgeInsets.fromLTRB(g, 10, 8, 10),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(
          top: BorderSide(color: t.rule, width: Tokens.hairline),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$nick wants to message you',
                  style: TextStyle(color: t.text, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                // Says what declining costs, because it is the destructive
                // choice and the one that cannot be walked back from here.
                Text(
                  'Declining blocks them on this network.',
                  style: TextStyle(color: t.faint, fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onDecline,
            style: TextButton.styleFrom(foregroundColor: t.muted),
            child: const Text('Decline'),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: onAccept,
            style: FilledButton.styleFrom(
              backgroundColor: t.accent,
              foregroundColor: t.onAccent,
            ),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }
}

/// Command completions, listed directly above the composer.
///
/// Above rather than below, and anchored to the composer rather than floating
/// over the scrollback: the list is about what is being typed, so it belongs
/// against the thing being typed into. It also means the newest messages stay
/// visible while a command is being written.
///
/// Enter picks the highlighted row instead of sending, because a bare command
/// name with no argument is not a message the server would accept anyway.
class _CommandSuggestions extends StatelessWidget {
  const _CommandSuggestions({
    required this.commands,
    required this.highlighted,
    required this.onPick,
  });

  final List<SlashCommand> commands;
  final int highlighted;
  final ValueChanged<SlashCommand> onPick;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;
    if (commands.isEmpty) return const Reveal();

    return Reveal(
      child: Container(
        decoration: BoxDecoration(
          color: t.surface,
          border: Border(
            top: BorderSide(color: t.rule, width: Tokens.hairline),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, command) in commands.indexed)
              _SuggestionRow(
                command: command,
                highlighted: i == highlighted.clamp(0, commands.length - 1),
                onTap: () => onPick(command),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(g, 4, g, 7),
              child: Text(
                '↑↓ to choose · Tab or Enter to complete · Esc to dismiss',
                style: TextStyle(color: t.faint, fontSize: 10.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.command,
    required this.highlighted,
    required this.onTap,
  });

  final SlashCommand command;
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Less the two points the selection rule takes, so the command name
    // starts on the same line as the messages above it either way.
    final g = context.layout.gutter;
    return Touchable(
      onTap: onTap,
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        decoration: BoxDecoration(
          color: highlighted
              ? t.surfaceHover
              : t.surfaceHover.withValues(alpha: touch.wash),
          border: Border(
            left: BorderSide(
              color: highlighted ? t.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: EdgeInsets.fromLTRB(g - 2, 6, g, 6),
        child: Row(
          children: [
            Text(
              '/${command.name}',
              style: TextStyle(
                color: t.accent,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 7),
            Text(
              command.usage,
              style: TextStyle(color: t.faint, fontSize: 11.5),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                command.description,
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: t.muted, fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A strip under the header for any connection that is not up.
///
/// The core reconnects on its own, so this is not an error to dismiss — it is
/// a progress report on something already happening. It says what is going on,
/// how long until the next attempt, and offers the one thing the user might
/// reasonably want that waiting does not give them: start again now.
class _ConnectionBar extends StatelessWidget {
  const _ConnectionBar({
    required this.status,
    required this.detail,
    required this.onRetry,
    required this.onViewLog,
  });

  /// Why, when the core said. Shown only where the state alone does not
  /// explain itself.
  final String? detail;

  final ConnectionStatus status;
  final VoidCallback onRetry;

  /// Opens the full account of what this connection has been doing.
  ///
  /// The bar has room for one sentence, and one sentence is not always the
  /// answer: a TLS complaint, a proxy that will not carry the connection, or a
  /// server refusing a password all need the sequence that led to them. That
  /// sequence used to be dumped into the conversation; it is one press away
  /// from here instead.
  final VoidCallback onViewLog;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final g = context.layout.gutter;

    // Connected is the silent case, and it is the common one — a bar that is
    // there whenever nothing is wrong is a bar nobody reads.
    final (color, label, waiting) = switch (status) {
      ConnectionStatus_Connected() => (t.ok, null, false),
      ConnectionStatus_Connecting() => (t.warn, 'Connecting…', true),
      ConnectionStatus_Registering() => (t.warn, 'Registering…', true),
      ConnectionStatus_Reconnecting(:final retryInSecs, :final attempt) => (
        t.warn,
        'Connection lost — retrying in ${retryInSecs}s (attempt $attempt)',
        true,
      ),
      // A session that has stopped trying has to say what stopped it. The
      // core gives up after a few attempts on a connection that never
      // worked, and "Disconnected" alone leaves the user guessing whether
      // the retry button beside it can possibly help.
      ConnectionStatus_Disconnected() => (
        t.bad,
        detail == null || detail!.isEmpty
            ? 'Disconnected'
            : 'Not connected — $detail',
        false,
      ),
    };

    return Reveal(
      child: label == null
          ? null
          : Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(g, 7, 10, 7),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                border: Border(
                  bottom: BorderSide(color: t.rule, width: Tokens.hairline),
                ),
              ),
              child: Row(
                children: [
                  // The spinner turns only while something is actually being
                  // attempted; a disconnected session is not working on it.
                  if (waiting) ...[
                    Spinner(color: color, size: 12),
                    const SizedBox(width: 9),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(color: color, fontSize: 12),
                    ),
                  ),
                  _ViewLog(onTap: onViewLog),
                  const SizedBox(width: 4),
                  _RetryNow(onTap: onRetry),
                ],
              ),
            ),
    );
  }
}

/// See what the connection has actually been doing.
///
/// Icon and label, like the retry beside it, but in the muted colour rather
/// than the accent: retrying is the thing being offered, and reading the log is
/// the thing available to someone who wants to know why they have to.
class _ViewLog extends StatelessWidget {
  const _ViewLog({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Tooltip(
      message: 'What this connection has been doing',
      child: Touchable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Tokens.radiusS),
        builder: (context, touch) => AnimatedContainer(
          duration: context.motion.fast,
          curve: Motion.curve,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
          decoration: BoxDecoration(
            color: t.surfaceHover.withValues(alpha: touch.wash),
            borderRadius: BorderRadius.circular(Tokens.radiusS),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.receipt_long_outlined, size: 14, color: t.muted),
              const SizedBox(width: 5),
              Text(
                'View log',
                style: TextStyle(
                  color: t.muted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Stop waiting out the backoff and dial again.
class _RetryNow extends StatefulWidget {
  const _RetryNow({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_RetryNow> createState() => _RetryNowState();
}

class _RetryNowState extends State<_RetryNow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  );

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  void _tap() {
    // The icon turns on press, and now it is the *only* acknowledgement: the
    // core wakes the connection it was already counting down on, so the
    // scrollback stays exactly where it was and nothing else on screen moves
    // until the status line changes to "connecting".
    if (!context.motion.disabled) _turn.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Touchable(
      onTap: _tap,
      borderRadius: BorderRadius.circular(Tokens.radiusS),
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: t.surfaceHover.withValues(alpha: touch.wash),
          borderRadius: BorderRadius.circular(Tokens.radiusS),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            RotationTransition(
              turns: CurvedAnimation(parent: _turn, curve: Motion.curve),
              child: Icon(Icons.refresh, size: 14, color: t.accent),
            ),
            const SizedBox(width: 5),
            Text(
              'Retry now',
              style: TextStyle(
                color: t.accent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
