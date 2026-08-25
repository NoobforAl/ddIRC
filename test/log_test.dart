// Tests for the log.
//
// The behaviour that matters here is mostly *negative*: that nothing is
// written unless it was asked for, that a chat log and a debug log stay
// separate, and that a credential never reaches the file. A logger that
// quietly writes when it was told not to is worse than no logger, because the
// user believes nothing is being kept.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/log.dart';

late Directory _dir;

File _file(String name) =>
    File('${_dir.path}${Platform.pathSeparator}$name');

Future<String> _read(String name) async {
  final file = _file(name);
  return await file.exists() ? file.readAsString() : '';
}

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('ddirc-log-test');
    AppLog.instance
      ..resetForTest()
      ..useDirectory(_dir);
  });

  tearDown(() {
    AppLog.instance.resetForTest();
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  });

  test('writes nothing at all until it is switched on', () async {
    AppLog.instance
      ..chat(network: 'ErgoTest', conversation: '#ddirc', text: 'hello')
      ..debug('connecting');
    await AppLog.instance.flush();

    // Not merely empty files — no files, and no folder. A user who never
    // enabled logging should find no trace of it on disk.
    expect(_dir.listSync(), isEmpty);
  });

  test('keeps what was said out of the debug log', () async {
    AppLog.instance.configure(chat: false, debug: true);
    AppLog.instance
      ..chat(network: 'ErgoTest', conversation: '#ddirc', text: 'a secret')
      ..debug('connected');
    await AppLog.instance.flush();

    expect(await _read('debug.log'), contains('connected'));
    // The point of the two switches being independent: someone debugging a
    // connection has not thereby agreed to record their conversations.
    expect(await _read('debug.log'), isNot(contains('a secret')));
    expect(await _read('chat.log'), isEmpty);
  });

  test('records a conversation when asked, with the network and channel',
      () async {
    AppLog.instance.configure(chat: true, debug: false);
    AppLog.instance.chat(
      network: 'ErgoTest',
      conversation: '#ddirc',
      text: '<ada> hello',
    );
    await AppLog.instance.flush();

    final written = await _read('chat.log');
    expect(written, contains('ErgoTest'));
    expect(written, contains('#ddirc'));
    expect(written, contains('<ada> hello'));
    expect(await _read('debug.log'), isEmpty);
  });

  test('stops immediately when switched off', () async {
    AppLog.instance.configure(chat: true, debug: false);
    AppLog.instance.chat(
      network: 'n',
      conversation: '#c',
      text: 'before',
    );
    await AppLog.instance.flush();

    AppLog.instance.configure(chat: false, debug: false);
    AppLog.instance.chat(network: 'n', conversation: '#c', text: 'after');
    await AppLog.instance.flush();

    final written = await _read('chat.log');
    expect(written, contains('before'));
    // Turning it off has to mean off now, not off after the next flush — the
    // user switching it off is usually reacting to something.
    expect(written, isNot(contains('after')));
  });

  test('clear removes the files', () async {
    AppLog.instance.configure(chat: true, debug: true);
    AppLog.instance
      ..chat(network: 'n', conversation: '#c', text: 'said')
      ..debug('did');
    await AppLog.instance.flush();
    expect(_dir.listSync(), isNotEmpty);

    await AppLog.instance.clear();
    expect(_dir.listSync(), isEmpty);
  });

  group('redaction', () {
    test('blanks anything that looks like a credential', () {
      expect(AppLog.redact('password: hunter2'), isNot(contains('hunter2')));
      expect(AppLog.redact('token=abc123'), isNot(contains('abc123')));
      expect(AppLog.redact('PASS oftc123'), isNot(contains('oftc123')));
      expect(
        AppLog.redact('AUTHENTICATE bWUAbWUAcGFzcw=='),
        isNot(contains('bWUAbWUAcGFzcw==')),
      );
    });

    test('leaves ordinary text alone', () {
      const line = 'connected to irc.example.org:6697 as ada';
      expect(AppLog.redact(line), line);
    });

    test('is applied on the way into the debug log', () async {
      AppLog.instance.configure(chat: false, debug: true);
      AppLog.instance.debug('sending PASS hunter2');
      await AppLog.instance.flush();

      final written = await _read('debug.log');
      expect(written, isNot(contains('hunter2')));
      expect(written, contains('redacted'));
    });
  });
}
