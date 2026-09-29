// The agent server: what an agent can read, that nothing is sent without the
// user, and that the HTTP door only opens for this machine with the token.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/mcp.dart';
import 'package:ddirc/src/model/session.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart';

const _plain = SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

ChatMessage _message(String sender, String text, {String? msgid}) =>
    ChatMessage(
      target: const Target.channel(name: '#one'),
      sender: sender,
      spans: [TextSpan(text: text, style: _plain)],
      isSelf: false,
      isMention: false,
      isAction: false,
      isNotice: false,
      msgid: msgid,
    );

/// A session on one channel with three lines in it, and no connection behind
/// it: nothing here reaches the native library until a send is attempted.
Future<SessionModel> _session() async {
  final session = SessionModel(
    connectionId: BigInt.zero,
    profileId: 'p1',
    config: const ServerConfig(
      host: 'example.test',
      port: 6697,
      nickname: 'me',
      altNicks: [],
      channels: [],
    ),
    settings: await AppSettings.load(),
  );
  session.requestForTesting('#one');
  session.receiveForTesting(
    const IrcEvent.joined(channel: '#one', nick: 'me', isSelf: true),
  );
  for (final (sender, text, id) in [
    ('alice', 'the build is green', 'm1'),
    ('bob', 'shipping tonight', 'm2'),
    ('alice', 'nice', 'm3'),
  ]) {
    session.receiveForTesting(
      IrcEvent.message(message: _message(sender, text, msgid: id)),
    );
  }
  return session;
}

Future<(McpService, SessionModel, ValueNotifier<bool>)> _service() async {
  SharedPreferences.setMockInitialValues({});
  final session = await _session();
  final mcp = await McpService.load();
  final locked = ValueNotifier(false);
  mcp.attachSource(
    McpSource(sessions: () => [session], nameOf: (_) => 'Example'),
    locked: locked,
  );
  return (mcp, session, locked);
}

Map<String, Object?> _structured(Map<String, Object?> result) {
  expect(result['isError'], isNot(true), reason: '$result');
  return result['structuredContent']! as Map<String, Object?>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('tools', () {
    test('networks and conversations are listed', () async {
      final (mcp, _, _) = await _service();
      final networks = _structured(await mcp.call('list_networks', {}));
      expect((networks['networks']! as List).single, containsPair('id', 'p1'));

      final conversations = _structured(
        await mcp.call('list_conversations', {'network': 'example'}),
      );
      expect(
        (conversations['conversations']! as List).single,
        containsPair('name', '#one'),
      );
    });

    test('messages are read oldest first, and page back', () async {
      final (mcp, _, _) = await _service();
      final read = _structured(
        await mcp.call('read_messages', {
          'network': 'p1',
          'conversation': '#ONE',
          'limit': 2,
        }),
      );
      final messages = read['messages']! as List;
      expect(messages.map((m) => (m as Map)['id']), ['m2', 'm3']);

      final older = _structured(
        await mcp.call('read_messages', {
          'network': 'p1',
          'conversation': '#one',
          'before': 'm2',
        }),
      );
      expect((older['messages']! as List).map((m) => (m as Map)['text']), [
        'the build is green',
      ]);
    });

    test('search finds text and senders, newest first', () async {
      final (mcp, _, _) = await _service();
      final found = _structured(
        await mcp.call('search_messages', {'query': 'alice'}),
      );
      expect((found['results']! as List).length, 2);
    });

    test('an unknown network is an error the agent can act on', () async {
      final (mcp, _, _) = await _service();
      final result = await mcp.call('list_conversations', {'network': 'nope'});
      expect(result['isError'], isTrue);
    });

    test('nothing is answered while the app is locked', () async {
      final (mcp, _, locked) = await _service();
      locked.value = true;
      final result = await mcp.call('list_networks', {});
      expect(result['isError'], isTrue);
      expect(jsonEncode(result), contains('locked'));
    });
  });

  group('sending', () {
    test('waits for the user, and a refusal sends nothing', () async {
      final (mcp, _, _) = await _service();
      final call = mcp.call('send_message', {
        'network': 'p1',
        'conversation': '#one',
        'text': 'hello from an agent',
        'reply_to': 'm2',
      });
      await Future<void>.delayed(Duration.zero);

      final request = mcp.pending.value.single;
      expect(request.text, 'hello from an agent');
      expect(request.conversation, '#one');
      expect(request.replyTo?.msgid, 'm2');
      expect(request.replyTo?.nick, 'bob');

      request.decide(McpDecision.deny);
      final result = _structured(await call);
      expect(result['sent'], isFalse);
      expect(mcp.pending.value, isEmpty);
    });

    test('"always" stops asking for that conversation', () async {
      final (mcp, _, _) = await _service();
      final first = mcp.call('send_message', {
        'network': 'p1',
        'conversation': '#one',
        'text': 'one',
      });
      await Future<void>.delayed(Duration.zero);
      mcp.pending.value.single.decide(McpDecision.always);
      // The send itself needs the native core, which a test does not have;
      // what matters here is that it got past the question.
      await first;
      expect(mcp.allowedCount, 1);

      final second = mcp.call('send_message', {
        'network': 'p1',
        'conversation': '#one',
        'text': 'two',
      });
      await Future<void>.delayed(Duration.zero);
      expect(mcp.pending.value, isEmpty, reason: 'not asked again');
      await second;
    });

    test('a message request not yet accepted cannot be answered', () async {
      final (mcp, session, _) = await _service();
      session.receiveForTesting(
        IrcEvent.message(
          message: ChatMessage(
            target: const Target.direct(nick: 'stranger'),
            sender: 'stranger',
            spans: const [TextSpan(text: 'hi', style: _plain)],
            isSelf: false,
            isMention: false,
            isAction: false,
            isNotice: false,
          ),
        ),
      );
      final result = await mcp.call('send_message', {
        'network': 'p1',
        'conversation': 'stranger',
        'text': 'hello',
      });
      expect(result['isError'], isTrue);
      expect(mcp.pending.value, isEmpty);
    });
  });

  group('http', () {
    late McpService mcp;
    late HttpClient client;

    setUp(() async {
      // The test binding answers every HTTP request with a 400 of its own;
      // these need the real network stack, on loopback.
      HttpOverrides.global = null;
      (mcp, _, _) = await _service();
      await mcp.setEnabled(true);
      expect(mcp.running, isTrue, reason: mcp.failure);
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await mcp.setEnabled(false);
    });

    Future<(int, Object?)> post(
      Object? body, {
      String? token,
      String? host,
      String? origin,
    }) async {
      final request = await client.postUrl(Uri.parse(mcp.endpoint!));
      request.headers.contentType = ContentType.json;
      if (token != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      }
      if (host != null) request.headers.host = host;
      if (origin != null) request.headers.set('origin', origin);
      request.write(jsonEncode(body));
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      Object? json;
      try {
        json = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        json = text;
      }
      return (response.statusCode, json);
    }

    const initialize = {
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'test', 'version': '0'},
      },
    };

    test('only this machine, and only with the token', () async {
      expect((await post(initialize)).$1, HttpStatus.unauthorized);
      expect(
        (await post(initialize, token: 'wrong')).$1,
        HttpStatus.unauthorized,
      );
      expect(
        (await post(initialize, token: mcp.token, host: 'evil.example')).$1,
        HttpStatus.forbidden,
        reason: 'a rebound DNS name is not this machine',
      );
      expect(
        (await post(
          initialize,
          token: mcp.token,
          origin: 'https://evil.example',
        )).$1,
        HttpStatus.forbidden,
        reason: 'a web page is not an agent',
      );
    });

    test('speaks MCP: initialize, tools, a call', () async {
      final (status, body) = await post(initialize, token: mcp.token);
      expect(status, HttpStatus.ok);
      final result = (body! as Map)['result'] as Map;
      expect(result['protocolVersion'], '2025-06-18');
      expect((result['serverInfo'] as Map)['name'], 'ddIRC');

      final (accepted, _) = await post({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      }, token: mcp.token);
      expect(accepted, HttpStatus.accepted);

      final (_, tools) = await post({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/list',
      }, token: mcp.token);
      final names = [
        for (final tool in ((tools! as Map)['result'] as Map)['tools'] as List)
          (tool as Map)['name'],
      ];
      expect(names, contains('send_message'));
      expect(names, contains('read_messages'));

      final (_, call) = await post({
        'jsonrpc': '2.0',
        'id': 3,
        'method': 'tools/call',
        'params': {'name': 'list_networks', 'arguments': <String, Object?>{}},
      }, token: mcp.token);
      final content = ((call! as Map)['result'] as Map)['content'] as List;
      expect((content.single as Map)['text'], contains('"p1"'));
    });

    test('an unknown method is a JSON-RPC error, not a crash', () async {
      final (status, body) = await post({
        'jsonrpc': '2.0',
        'id': 9,
        'method': 'resources/list',
      }, token: mcp.token);
      expect(status, HttpStatus.ok);
      expect(((body! as Map)['error'] as Map)['code'], -32601);
    });
  });
}
