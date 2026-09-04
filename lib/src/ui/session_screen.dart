import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/profile.dart';
import '../model/media.dart';
import '../model/notice.dart';
import '../model/session.dart';
import '../model/transfer.dart';
import '../model/settings.dart';
import '../model/workspace.dart';
import '../rust/api/types.dart';
import '../theme.dart';
import 'channel_list.dart';
import 'conversation_tabs.dart';
import 'layout.dart';
import 'member_list.dart';
import 'menu.dart';
import 'message_view.dart';
import 'motion.dart';
import 'notice_bar.dart';
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

  SessionModel get session => widget.session;

  @override
  void initState() {
    super.initState();
    session.addListener(_onChanged);
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
    session.removeListener(_onChanged);
    _composer.removeListener(_onTyped);
    _composerFocus.onKeyEvent = null;
    _composer.dispose();
    _composerFocus.dispose();
    _suggestionRevision.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    final error = await session.submit(text);
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
            // Closable either way. Beside the conversation the cross puts the
            // setting back; in a drawer it dismisses the drawer. A panel the
            // user turned on and cannot turn off from where they are looking
            // at it is the reason it was always on in the first place.
            onClose: layout.membersPinned
                ? () => SettingsScope.of(context).showMembers = false
                : () => Navigator.of(context).maybePop(),
            onOpenDirect: _openDirect,
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
    return Column(
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
        ),
        // Anything other than "connected" gets a bar of its own. The status
        // dot in the header can say something is wrong, but it has nowhere to
        // put the reason, the countdown, or a way to stop waiting.
        _ConnectionBar(
          status: session.status,
          detail: session.statusDetail,
          onRetry: _retry,
        ),
        ConversationTabs(
          session: session,
          onSelect: session.select,
          onClose: session.closeTab,
        ),
        // A topic arriving, or switching to a channel that has none, moves
        // the whole scrollback. Unrolling it says which way everything went.
        Reveal(child: topic == null ? null : _TopicBar(topic: topic)),
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
                    // Rebuild the scroll state when switching conversations.
                    key: ValueKey(active.name),
                    conversation: active,
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
        NoticeReveal(notice: session.notice, onDismiss: session.dismissNotice),
        ListenableBuilder(
          listenable: _suggestionRevision,
          builder: (context, _) => _CommandSuggestions(
            commands: _suggestions,
            highlighted: _highlighted,
            onPick: _complete,
          ),
        ),
        _composerBar(t, active),
      ],
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
      padding: EdgeInsets.fromLTRB(g, 8, 8, 10),
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
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 11,
                ),
                enabledBorder: _border(t.rule, Tokens.hairline),
                focusedBorder: _border(t.accent, 1),
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
          IconButton(
            onPressed: _submit,
            icon: const Icon(Icons.arrow_upward, size: 19),
            color: t.accent,
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }

  static OutlineInputBorder _border(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(7),
        borderSide: BorderSide(color: color, width: width),
      );
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
  });

  final SessionModel session;
  final Conversation? conversation;
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
          ),
        ],
      ),
    );
  }
}

/// The one place every settings dialog can be reached from.
enum _SettingsTarget { channel, server, network, app }

class _SettingsMenu extends StatelessWidget {
  const _SettingsMenu({
    required this.hasChannel,
    required this.channelName,
    required this.onChannelSettings,
    required this.onServerSettings,
    required this.onNetworkEditor,
    required this.onAppSettings,
  });

  final bool hasChannel;
  final String? channelName;
  final VoidCallback onChannelSettings;
  final VoidCallback onServerSettings;
  final VoidCallback onNetworkEditor;
  final VoidCallback onAppSettings;

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
        _SettingsTarget.channel => onChannelSettings(),
        _SettingsTarget.server => onServerSettings(),
        _SettingsTarget.network => onNetworkEditor(),
        _SettingsTarget.app => onAppSettings(),
      },
      itemBuilder: (context) => [
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
  });

  /// Why, when the core said. Shown only where the state alone does not
  /// explain itself.
  final String? detail;

  final ConnectionStatus status;
  final VoidCallback onRetry;

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
                  _RetryNow(onTap: onRetry),
                ],
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
      borderRadius: BorderRadius.circular(6),
      builder: (context, touch) => AnimatedContainer(
        duration: context.motion.fast,
        curve: Motion.curve,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: t.surfaceHover.withValues(alpha: touch.wash),
          borderRadius: BorderRadius.circular(6),
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
