import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../rust/api/types.dart';
import '../version.dart';
import 'secrets.dart';
import 'session.dart';
import 'workspace.dart';

/// What the user said to an agent asking to send a message.
enum McpDecision { once, always, deny }

/// A message an agent wants sent, waiting for the user.
class McpSendRequest {
  McpSendRequest({
    required this.profileId,
    required this.networkName,
    required this.conversation,
    required this.text,
    this.replyTo,
  });

  final String profileId;
  final String networkName;
  final String conversation;
  final String text;
  final ReplyRef? replyTo;

  final _answer = Completer<McpDecision>();
  Future<McpDecision> get decision => _answer.future;

  void decide(McpDecision decision) {
    if (!_answer.isCompleted) _answer.complete(decision);
  }
}

/// One thing an agent did, for the activity list in settings.
@immutable
class McpActivity {
  const McpActivity(this.at, this.tool, this.summary, {this.ok = true});

  final DateTime at;
  final String tool;
  final String summary;
  final bool ok;
}

/// A way for an AI agent to take part: a Model Context Protocol server inside
/// the app — beta, and off until switched on.
///
/// # What an agent can do
///
/// Read: which networks are connected, which conversations are open on them,
/// what was said in one, and a search across them. Write: one thing only,
/// sending a message to a conversation that is already open — and never
/// without the user saying yes. Each send waits on an approval sheet in the
/// app showing exactly what would be sent and where; the user can allow it
/// once, allow that one conversation from then on, or refuse. Nothing else —
/// no joining, no leaving, no commands — because a message is the only action
/// whose whole effect can be read off a sheet before it happens.
///
/// # How it is reached
///
/// The MCP "Streamable HTTP" transport, answered with plain JSON: `POST` a
/// JSON-RPC request to `/mcp`, get the response back in the body. On
/// `127.0.0.1` only, on a port kept between runs so a configured client keeps
/// working, and behind a random bearer token held in the platform's secure
/// storage. A request is also refused when its `Host` is not this loopback
/// address or it carries a web `Origin` from anywhere else: those two are
/// what stop a web page in a browser on this machine from talking to it
/// (DNS rebinding), which a loopback bind on its own does not.
///
/// While the app is locked every call is refused — a locked app that still
/// answered questions about its scrollback would not be locked.
class McpService extends ChangeNotifier {
  McpService._(this._prefs);

  static const _kEnabled = 'mcp.enabled';
  static const _kPort = 'mcp.port';
  static const _kAllowed = 'mcp.allowed';
  static const _secretKey = 'mcp.token';

  /// How long a send waits for the user before counting as refused.
  static const approvalTimeout = Duration(minutes: 2);

  /// Protocol versions this server speaks, newest first.
  static const protocolVersions = ['2025-06-18', '2025-03-26', '2024-11-05'];

  static const _maxBody = 1 << 20;
  static const _maxActivity = 50;
  static const maxText = 2000;

  final SharedPreferences? _prefs;

  bool _enabled = false;
  int? _savedPort;
  String? _token;
  HttpServer? _server;
  String? _failure;
  Set<String> _allowed = {};
  final List<McpActivity> _activity = [];

  McpSource? _source;
  ValueListenable<bool>? _locked;

  /// Sends waiting for the user, oldest first. The app shows the first.
  final pending = ValueNotifier<List<McpSendRequest>>(const []);

  bool get enabled => _enabled;
  bool get running => _server != null;
  int? get port => _server?.port;
  String? get failure => _failure;
  String? get token => _token;
  List<McpActivity> get activity => List.unmodifiable(_activity);

  /// Conversations whose sends no longer need asking about.
  int get allowedCount => _allowed.length;

  String? get endpoint => port == null ? null : 'http://127.0.0.1:$port/mcp';

  /// The command that registers this server with Claude Code, ready to paste.
  String? get claudeCodeCommand {
    final url = endpoint;
    final token = _token;
    if (url == null || token == null) return null;
    return 'claude mcp add --transport http ddirc $url '
        '--header "Authorization: Bearer $token"';
  }

  static Future<McpService> load() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      debugPrint('agent server preference unavailable, starting off: $e');
    }
    final service = McpService._(prefs);
    service._enabled = prefs?.getBool(_kEnabled) ?? false;
    service._savedPort = prefs?.getInt(_kPort);
    service._allowed = {...?prefs?.getStringList(_kAllowed)};
    return service;
  }

  /// What the tools read from and send through, and when to refuse.
  void attach(Workspace workspace, {ValueListenable<bool>? locked}) =>
      attachSource(
        McpSource(
          sessions: () => workspace.sessions,
          nameOf: (id) => workspace.profiles.byId(id)?.name,
        ),
        locked: locked,
      );

  /// [attach], from anything that can list sessions — the tests, which have
  /// sessions but no saved networks behind them.
  void attachSource(McpSource source, {ValueListenable<bool>? locked}) {
    _source = source;
    _locked = locked;
  }

  Future<void> startIfEnabled() async {
    if (_enabled) await _start();
  }

  Future<void> setEnabled(bool value) async {
    if (value == _enabled && value == running) return;
    _enabled = value;
    await _prefs?.setBool(_kEnabled, value);
    notifyListeners();
    if (value) {
      await _start();
    } else {
      await _stop();
    }
  }

  /// A new token. Every client configured with the old one stops working,
  /// which is the point: it is how access is taken back.
  Future<void> regenerateToken() async {
    _token = _newToken();
    await _writeToken(_token!);
    notifyListeners();
  }

  /// Every send asks again.
  Future<void> forgetAllowed() async {
    _allowed = {};
    await _prefs?.setStringList(_kAllowed, const []);
    notifyListeners();
  }

  Future<void> _start() async {
    _failure = null;
    try {
      _token ??= await _readToken();
      if (_token == null) {
        _token = _newToken();
        await _writeToken(_token!);
      }
      _server = await _bind();
      await _prefs?.setInt(_kPort, _server!.port);
      _server!.listen(_handle, onError: (Object e) => debugPrint('mcp: $e'));
    } catch (e) {
      _server = null;
      _failure = '$e';
    }
    notifyListeners();
  }

  /// The port used last time, so a client already configured keeps working;
  /// any free one when that is taken.
  Future<HttpServer> _bind() async {
    final saved = _savedPort;
    if (saved != null) {
      try {
        return await HttpServer.bind(InternetAddress.loopbackIPv4, saved);
      } on SocketException {
        // Taken by something else since. A new port, and the settings screen
        // shows it.
      }
    }
    return HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  }

  Future<void> _stop() async {
    final server = _server;
    _server = null;
    for (final request in pending.value) {
      request.decide(McpDecision.deny);
    }
    pending.value = const [];
    notifyListeners();
    await server?.close(force: true);
  }

  static String _newToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<String?> _readToken() async {
    try {
      return await secrets.read(key: _secretKey);
    } catch (e) {
      debugPrint('agent token unreadable, making a new one: $e');
      return null;
    }
  }

  Future<void> _writeToken(String token) async {
    try {
      await secrets.write(key: _secretKey, value: token);
    } catch (e) {
      // Kept in memory for this run: clients will need the new one after a
      // restart, which the settings screen shows.
      debugPrint('agent token could not be stored: $e');
    }
  }

  void _record(String tool, String summary, {bool ok = true}) {
    _activity.insert(0, McpActivity(DateTime.now(), tool, summary, ok: ok));
    if (_activity.length > _maxActivity) _activity.removeLast();
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_stop());
    pending.dispose();
    super.dispose();
  }

  // ---- HTTP ----------------------------------------------------------------

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_hostIsLoopback(request) || !_originIsLoopback(request)) {
        return await _plain(response, HttpStatus.forbidden, 'forbidden');
      }
      if (request.uri.path != '/mcp') {
        return await _plain(response, HttpStatus.notFound, 'not found');
      }
      if (!_authorised(request)) {
        response.headers.set(HttpHeaders.wwwAuthenticateHeader, 'Bearer');
        return await _plain(response, HttpStatus.unauthorized, 'unauthorized');
      }
      switch (request.method) {
        case 'POST':
          break;
        case 'DELETE':
          // No sessions are kept, so ending one is always already done.
          return await _plain(response, HttpStatus.ok, '');
        default:
          // No server-to-client stream: every answer comes back in the body
          // of the request that asked for it.
          response.headers.set(HttpHeaders.allowHeader, 'POST, DELETE');
          return await _plain(
            response,
            HttpStatus.methodNotAllowed,
            'use POST',
          );
      }

      final body = await _readBody(request);
      if (body == null) {
        return await _plain(
          response,
          HttpStatus.requestEntityTooLarge,
          'too large',
        );
      }
      Object? parsed;
      try {
        parsed = jsonDecode(body);
      } on FormatException {
        return await _json(response, _error(null, -32700, 'parse error'));
      }

      if (parsed is List) {
        final answers = <Object?>[];
        for (final message in parsed) {
          final answer = await _rpc(message);
          if (answer != null) answers.add(answer);
        }
        if (answers.isEmpty) {
          return await _plain(response, HttpStatus.accepted, '');
        }
        return await _json(response, answers);
      }
      final answer = await _rpc(parsed);
      if (answer == null) {
        return await _plain(response, HttpStatus.accepted, '');
      }
      return await _json(response, answer);
    } catch (e) {
      debugPrint('mcp request failed: $e');
      try {
        await _plain(response, HttpStatus.internalServerError, 'error');
      } catch (_) {}
    }
  }

  bool _hostIsLoopback(HttpRequest request) {
    final host = request.headers.host;
    return host == null ||
        host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '[::1]' ||
        host == '::1';
  }

  bool _originIsLoopback(HttpRequest request) {
    final origin = request.headers.value('origin');
    if (origin == null || origin == 'null') return origin == null;
    final uri = Uri.tryParse(origin);
    return uri != null &&
        (uri.host == '127.0.0.1' ||
            uri.host == 'localhost' ||
            uri.host == '::1');
  }

  bool _authorised(HttpRequest request) {
    final token = _token;
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    if (token == null || header == null) return false;
    const scheme = 'Bearer ';
    if (!header.startsWith(scheme)) return false;
    return _sameSecret(header.substring(scheme.length).trim(), token);
  }

  /// Compared in time that does not depend on where they first differ.
  static bool _sameSecret(String a, String b) {
    final x = utf8.encode(a);
    final y = utf8.encode(b);
    var diff = x.length ^ y.length;
    for (var i = 0; i < x.length && i < y.length; i++) {
      diff |= x[i] ^ y[i];
    }
    return diff == 0;
  }

  static Future<String?> _readBody(HttpRequest request) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request) {
      bytes.add(chunk);
      if (bytes.length > _maxBody) return null;
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  static Future<void> _plain(HttpResponse response, int status, String text) {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write(text);
    return response.close();
  }

  static Future<void> _json(HttpResponse response, Object? body) {
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    return response.close();
  }

  // ---- JSON-RPC --------------------------------------------------------------

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  static Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  /// One JSON-RPC message in, its answer out — or null for a notification,
  /// which gets none.
  Future<Map<String, Object?>?> _rpc(Object? message) async {
    if (message is! Map) return _error(null, -32600, 'invalid request');
    final id = message['id'];
    final method = message['method'];
    final params = message['params'];
    final notification = !message.containsKey('id');
    if (method is! String) {
      return notification ? null : _error(id, -32600, 'invalid request');
    }
    if (notification) return null;

    switch (method) {
      case 'initialize':
        final asked = params is Map ? params['protocolVersion'] : null;
        return _result(id, {
          'protocolVersion': protocolVersions.contains(asked)
              ? asked
              : protocolVersions.first,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {'name': 'ddIRC', 'version': appVersion},
          'instructions':
              'ddIRC is an IRC client. Use list_networks, then '
              'list_conversations, then read_messages to catch up. '
              'send_message posts to a conversation that is already open, and '
              'waits for the user to approve it in the app.',
        });
      case 'ping':
        return _result(id, const <String, Object?>{});
      case 'tools/list':
        return _result(id, {'tools': tools});
      case 'tools/call':
        if (params is! Map || params['name'] is! String) {
          return _error(id, -32602, 'tools/call needs a name');
        }
        final arguments = params['arguments'];
        return _result(
          id,
          await call(
            params['name'] as String,
            arguments is Map ? arguments.cast<String, Object?>() : const {},
          ),
        );
      default:
        return _error(id, -32601, 'method not found: $method');
    }
  }

  // ---- Tools -----------------------------------------------------------------

  static const tools = <Map<String, Object?>>[
    {
      'name': 'list_networks',
      'title': 'List networks',
      'description':
          'The IRC networks ddIRC is connected to right now, with your nick '
          'and the connection state on each.',
      'inputSchema': {'type': 'object', 'properties': <String, Object?>{}},
      'annotations': {'readOnlyHint': true},
    },
    {
      'name': 'list_conversations',
      'title': 'List conversations',
      'description':
          'The channels and direct messages open on one network, with unread '
          'counts and topics.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'network': {
            'type': 'string',
            'description': 'A network id or name from list_networks.',
          },
        },
        'required': ['network'],
      },
      'annotations': {'readOnlyHint': true},
    },
    {
      'name': 'read_messages',
      'title': 'Read messages',
      'description':
          'Recent messages in one conversation, oldest first. Each has an id '
          'that send_message can reply to. Page back with `before`.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'network': {'type': 'string'},
          'conversation': {
            'type': 'string',
            'description': 'A channel like #rust, or a nick for a DM.',
          },
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 200,
            'default': 50,
          },
          'before': {
            'type': 'string',
            'description': 'Only messages older than the one with this id.',
          },
          'include_system': {
            'type': 'boolean',
            'default': false,
            'description': 'Also joins, parts, topic and mode changes.',
          },
        },
        'required': ['network', 'conversation'],
      },
      'annotations': {'readOnlyHint': true},
    },
    {
      'name': 'search_messages',
      'title': 'Search messages',
      'description':
          'Case-insensitive text search over the messages ddIRC holds in '
          'memory, newest first. Optionally narrowed to one network or '
          'conversation.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'minLength': 2},
          'network': {'type': 'string'},
          'conversation': {'type': 'string'},
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 200,
            'default': 50,
          },
        },
        'required': ['query'],
      },
      'annotations': {'readOnlyHint': true},
    },
    {
      'name': 'send_message',
      'title': 'Send a message',
      'description':
          'Send a message to a conversation that is already open. The user '
          'is shown the exact text and must approve it in ddIRC, so this '
          'waits for them — up to two minutes — and says whether it was sent. '
          'Pass reply_to with a message id from read_messages to reply to it.',
      'inputSchema': {
        'type': 'object',
        'properties': {
          'network': {'type': 'string'},
          'conversation': {'type': 'string'},
          'text': {'type': 'string', 'minLength': 1, 'maxLength': maxText},
          'reply_to': {
            'type': 'string',
            'description': 'The id of the message this answers.',
          },
        },
        'required': ['network', 'conversation', 'text'],
      },
      'annotations': {'readOnlyHint': false, 'destructiveHint': false},
    },
  ];

  /// Run one tool. Public for the tests; the HTTP side is a thin wrapper.
  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> args,
  ) async {
    if (_locked?.value ?? false) {
      _record(name, 'refused: the app is locked', ok: false);
      return _fail('ddIRC is locked. Ask the user to unlock it.');
    }
    final workspace = _source;
    if (workspace == null) return _fail('ddIRC is still starting.');
    try {
      final result = switch (name) {
        'list_networks' => _listNetworks(workspace),
        'list_conversations' => _listConversations(workspace, args),
        'read_messages' => _readMessages(workspace, args),
        'search_messages' => _search(workspace, args),
        'send_message' => await _send(workspace, args),
        _ => throw _ToolError('no such tool: $name'),
      };
      return {
        'content': [
          {'type': 'text', 'text': jsonEncode(result)},
        ],
        'structuredContent': result,
      };
    } on _ToolError catch (e) {
      _record(name, e.message, ok: false);
      return _fail(e.message);
    }
  }

  static Map<String, Object?> _fail(String message) => {
    'content': [
      {'type': 'text', 'text': message},
    ],
    'isError': true,
  };

  Map<String, Object?> _listNetworks(McpSource workspace) {
    final networks = [
      for (final session in workspace.sessions())
        {
          'id': session.profileId,
          'name':
              workspace.nameOf(session.profileId) ??
              session.network ??
              session.profileId,
          'network': session.network,
          'nick': session.nick,
          'status': _status(session.status),
        },
    ];
    _record('list_networks', '${networks.length} connected');
    return {'networks': networks};
  }

  static String _status(ConnectionStatus status) => switch (status) {
    ConnectionStatus_Disconnected() => 'disconnected',
    ConnectionStatus_Connecting() => 'connecting',
    ConnectionStatus_Registering() => 'registering',
    ConnectionStatus_Connected() => 'connected',
    ConnectionStatus_Reconnecting() => 'reconnecting',
  };

  SessionModel _session(McpSource workspace, Object? network) {
    if (network is! String || network.isEmpty) {
      throw const _ToolError('network is required');
    }
    final wanted = network.toLowerCase();
    for (final session in workspace.sessions()) {
      final profile = workspace.nameOf(session.profileId);
      if (session.profileId == network ||
          profile?.toLowerCase() == wanted ||
          session.network?.toLowerCase() == wanted) {
        return session;
      }
    }
    throw _ToolError('not connected to "$network" — see list_networks');
  }

  Conversation _conversation(SessionModel session, Object? name) {
    if (name is! String || name.isEmpty) {
      throw const _ToolError('conversation is required');
    }
    final wanted = name.toLowerCase();
    for (final conversation in session.conversations) {
      if (conversation.name.toLowerCase() == wanted) return conversation;
    }
    throw _ToolError('no open conversation "$name" — see list_conversations');
  }

  Map<String, Object?> _listConversations(
    McpSource workspace,
    Map<String, Object?> args,
  ) {
    final session = _session(workspace, args['network']);
    final conversations = [
      for (final c in session.conversations)
        {
          'name': c.name,
          'kind': c.isChannel ? 'channel' : 'direct',
          'unread': c.unread,
          'mentions': c.unreadMentions,
          if (c.topic != null) 'topic': c.topic,
          if (c.isChannel) 'members': c.members.length,
          if (c.pending) 'pending_request': true,
        },
    ];
    _record(
      'list_conversations',
      '${conversations.length} on ${args['network']}',
    );
    return {'conversations': conversations};
  }

  static int _limit(Object? value) => value is int
      ? value.clamp(1, 200)
      : (value is num ? value.toInt().clamp(1, 200) : 50);

  /// An id an agent can hand back: the server's own when it tags messages,
  /// and one made from when and who otherwise.
  static String idOf(ChatLine line) =>
      line.message?.msgid ??
      'local-${line.at.microsecondsSinceEpoch}-${line.message?.sender ?? 'system'}';

  static String _text(ChatMessage message) =>
      message.spans.map((s) => s.text).join();

  static Map<String, Object?> _describe(ChatLine line) {
    final message = line.message;
    final time = line.at.toUtc().toIso8601String();
    if (message == null) {
      return {'id': idOf(line), 'time': time, 'system': line.system};
    }
    final reply = message.replyTo;
    return {
      'id': idOf(line),
      'time': time,
      'sender': message.sender,
      'text': _text(message),
      if (message.isSelf) 'self': true,
      if (message.isMention) 'mention': true,
      if (message.isAction) 'action': true,
      if (message.isNotice) 'notice': true,
      if (reply != null)
        'reply_to': {
          if (reply.msgid != null) 'id': reply.msgid,
          if (reply.nick.isNotEmpty) 'sender': reply.nick,
          if (reply.excerpt.isNotEmpty) 'excerpt': reply.excerpt,
        },
    };
  }

  Map<String, Object?> _readMessages(
    McpSource workspace,
    Map<String, Object?> args,
  ) {
    final session = _session(workspace, args['network']);
    final conversation = _conversation(session, args['conversation']);
    final limit = _limit(args['limit']);
    final withSystem = args['include_system'] == true;

    var lines = conversation.lines;
    final before = args['before'];
    if (before is String) {
      final at = lines.indexWhere((l) => idOf(l) == before);
      if (at >= 0) lines = lines.sublist(0, at);
    }
    final picked = <ChatLine>[];
    for (var i = lines.length - 1; i >= 0 && picked.length < limit; i--) {
      if (!withSystem && lines[i].isSystem) continue;
      picked.add(lines[i]);
    }
    _record('read_messages', '${picked.length} from ${conversation.name}');
    return {
      'conversation': conversation.name,
      'messages': [for (final l in picked.reversed) _describe(l)],
    };
  }

  Map<String, Object?> _search(McpSource workspace, Map<String, Object?> args) {
    final query = args['query'];
    if (query is! String || query.trim().length < 2) {
      throw const _ToolError('query needs at least two characters');
    }
    final needle = query.toLowerCase();
    final limit = _limit(args['limit']);
    final sessions = args['network'] == null
        ? workspace.sessions()
        : [_session(workspace, args['network'])];

    final found = <Map<String, Object?>>[];
    for (final session in sessions) {
      final conversations = args['conversation'] == null
          ? session.conversations
          : [_conversation(session, args['conversation'])];
      for (final conversation in conversations) {
        for (final line in conversation.lines) {
          final message = line.message;
          if (message == null) continue;
          if (_text(message).toLowerCase().contains(needle) ||
              message.sender.toLowerCase().contains(needle)) {
            found.add({
              'network': session.profileId,
              'conversation': conversation.name,
              ..._describe(line),
            });
          }
        }
      }
    }
    found.sort(
      (a, b) => (b['time']! as String).compareTo(a['time']! as String),
    );
    final results = found.take(limit).toList();
    _record('search_messages', '${results.length} for "$query"');
    return {'results': results};
  }

  static String _allowKey(String profileId, String conversation) =>
      '$profileId\n${conversation.toLowerCase()}';

  Future<Map<String, Object?>> _send(
    McpSource workspace,
    Map<String, Object?> args,
  ) async {
    final session = _session(workspace, args['network']);
    final conversation = _conversation(session, args['conversation']);
    if (conversation.pending) {
      throw const _ToolError(
        'that is a message request the user has not accepted',
      );
    }
    final text = args['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const _ToolError('text is required');
    }
    if (text.length > maxText) {
      throw const _ToolError('text is longer than $maxText characters');
    }

    ReplyRef? replyTo;
    final replyId = args['reply_to'];
    if (replyId is String) {
      final original = conversation.lines
          .where((l) => l.message != null && idOf(l) == replyId)
          .lastOrNull;
      if (original == null) {
        throw _ToolError(
          'no message with id "$replyId" in ${conversation.name}',
        );
      }
      final message = original.message!;
      replyTo = ReplyRef(
        msgid: message.msgid,
        nick: message.sender,
        excerpt: _text(message),
      );
    }

    final key = _allowKey(session.profileId, conversation.name);
    if (!_allowed.contains(key)) {
      final request = McpSendRequest(
        profileId: session.profileId,
        networkName:
            workspace.nameOf(session.profileId) ??
            session.network ??
            session.profileId,
        conversation: conversation.name,
        text: text,
        replyTo: replyTo,
      );
      pending.value = [...pending.value, request];
      final decision = await request.decision.timeout(
        approvalTimeout,
        onTimeout: () => McpDecision.deny,
      );
      pending.value = [
        for (final r in pending.value)
          if (!identical(r, request)) r,
      ];
      if (decision == McpDecision.deny) {
        _record('send_message', 'refused for ${conversation.name}', ok: false);
        return {'sent': false, 'reason': 'the user did not approve it'};
      }
      if (decision == McpDecision.always) {
        _allowed = {..._allowed, key};
        await _prefs?.setStringList(_kAllowed, _allowed.toList());
      }
    }

    final error = await session.say(conversation.name, text, replyTo: replyTo);
    if (error != null) throw _ToolError(error);
    _record('send_message', 'sent to ${conversation.name}');
    return {'sent': true, 'conversation': conversation.name};
  }
}

/// What the tools read from: the live sessions, and what the user named each
/// network.
class McpSource {
  const McpSource({required this.sessions, required this.nameOf});

  final List<SessionModel> Function() sessions;
  final String? Function(String profileId) nameOf;
}

class _ToolError implements Exception {
  const _ToolError(this.message);
  final String message;
}

/// Makes [McpService] available to the widget tree.
class McpScope extends InheritedNotifier<McpService> {
  const McpScope({super.key, required McpService mcp, required super.child})
    : super(notifier: mcp);

  static McpService of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<McpScope>();
    assert(scope?.notifier != null, 'No McpScope above this widget');
    return scope!.notifier!;
  }

  static McpService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<McpScope>()?.notifier;
}
