import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../rust/api/client.dart' as core;
import '../rust/api/types.dart';
import 'settings.dart';

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
  Conversation({required this.name, required this.isChannel});

  final String name;
  final bool isChannel;

  final List<ChatLine> lines = [];
  List<MemberView> members = const [];
  String? topic;

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
}

/// Owns everything the UI renders for one server connection.
///
/// Reads the event stream from the Rust core and fans events out into
/// per-conversation buffers. All protocol decisions (mention detection, control
/// character stripping, own-message echo) already happened in the core; this
/// class only routes and presents.
class SessionModel extends ChangeNotifier {
  SessionModel({
    required this.connectionId,
    required this.profileId,
    required this.config,
    required this.settings,
  }) : _nick = config.nickname;

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

  String _nick;
  String? _active;
  String? _network;
  ConnectionStatus _status = const ConnectionStatus.connecting();
  AuthOutcome? _auth;
  StreamSubscription<IrcEvent>? _subscription;

  String get nick => _nick;
  String? get network => _network;
  ConnectionStatus get status => _status;
  AuthOutcome? get auth => _auth;

  /// Conversations in the order they were opened.
  UnmodifiableListView<Conversation> get conversations =>
      UnmodifiableListView(_order.map((k) => _conversations[k]!));

  Conversation? get active => _active == null ? null : _conversations[_active];

  int get totalUnread =>
      _conversations.values.fold(0, (sum, c) => sum + c.unread);

  int get totalMentions =>
      _conversations.values.fold(0, (sum, c) => sum + c.unreadMentions);

  bool get isConnected => _status is ConnectionStatus_Connected;

  void start() {
    // Fed from the Rust network runtime, so a flooding channel never stalls
    // the UI thread.
    _subscription = core.eventStream(id: connectionId).listen(_onEvent);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    core.disconnect(id: connectionId, reason: 'ddIRC');
    super.dispose();
  }

  /// Conversation keys are case-insensitive: IRC treats `#Foo` and `#foo` as
  /// one channel, and the server may use either casing at different times.
  String _key(String name) => name.toLowerCase();

  Conversation _conversationFor(String name, {required bool isChannel}) {
    final key = _key(name);
    final existing = _conversations[key];
    if (existing != null) return existing;

    final created = Conversation(name: name, isChannel: isChannel);
    _conversations[key] = created;
    _order.add(key);
    // The first conversation to appear becomes the active one, so the user is
    // never looking at an empty screen after joining.
    _active ??= key;
    return created;
  }

  void select(String name) {
    final key = _key(name);
    if (!_conversations.containsKey(key)) return;
    _active = key;
    _conversations[key]!.markRead();
    notifyListeners();
  }

  void _addLine(String name, ChatLine line, {required bool isChannel}) {
    final conversation = _conversationFor(name, isChannel: isChannel);
    conversation.add(
      line,
      active: _key(name) == _active,
      notify: settings.notifyFor(profileId, name),
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
        _addToActive(_describeStatus(status, detail));

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
        _addLine(name, ChatLine.message(message, now), isChannel: isChannel);

      case IrcEvent_Joined(:final channel, :final nick, :final isSelf):
        _addLine(
          channel,
          ChatLine.system(
            isSelf ? 'you joined $channel' : '$nick joined',
            now,
            SystemKind.presence,
          ),
          isChannel: true,
        );
        if (isSelf) {
          _active ??= _key(channel);
          select(channel);
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
        // A full roster, not a delta — replacing wholesale keeps the UI from
        // drifting out of sync with the core.
        _conversationFor(channel, isChannel: true).members = members;

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

      case IrcEvent_Error(:final message):
        _addToActive('error: $message');
    }
    notifyListeners();
  }

  void _close(String channel) {
    final key = _key(channel);
    _conversations.remove(key);
    _order.remove(key);
    if (_active == key) {
      _active = _order.isEmpty ? null : _order.last;
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
      await core.sendMessage(id: connectionId, target: target.name, text: text);
      return null;
    }

    final body = text.substring(1);
    final split = body.indexOf(' ');
    final command = (split == -1 ? body : body.substring(0, split))
        .toLowerCase();
    final argument = split == -1 ? '' : body.substring(split + 1).trim();

    try {
      switch (command) {
        case 'join' when argument.isNotEmpty:
          await core.join(id: connectionId, channel: argument);
        case 'part':
          final target = active;
          if (target == null) return 'not in a channel';
          await core.part_(
            id: connectionId,
            channel: target.name,
            reason: argument.isEmpty ? null : argument,
          );
        case 'nick' when argument.isNotEmpty:
          await core.setNick(id: connectionId, nick: argument);
        case 'me' when argument.isNotEmpty:
          final target = active;
          if (target == null) return 'not in a channel';
          await core.sendAction(
            id: connectionId,
            target: target.name,
            text: argument,
          );
        case 'msg':
          final gap = argument.indexOf(' ');
          if (gap == -1) return 'usage: /msg <target> <message>';
          await core.sendMessage(
            id: connectionId,
            target: argument.substring(0, gap),
            text: argument.substring(gap + 1),
          );
        default:
          return 'unknown command: /$command';
      }
    } catch (e) {
      return '$e';
    }
    return null;
  }
}
