// Where inherited state may be read from.
//
// A structural test rather than a behavioural one, and it exists because the
// bug it guards against was unreachable from a behavioural test. The network
// editor read the profile store from `initState`, which Flutter forbids —
// inherited widgets have no dependencies to look up that early, so it asserts,
// and in a debug build that assertion is a red screen where the dialog should
// be. It shipped because the editor cannot be pumped in a widget test at all:
// it asks the native core for the default TLS port while building its fields,
// and there is no core here.
//
// So the only place this class of mistake can be caught is in the source. It
// is worth catching: the failure is silent in release, loud in debug, and lands
// on whichever single code path happens to reach the lookup — here, editing a
// saved network, while adding one was fine, because a new network has no stored
// password to ask about.
//
// The right place for these is `didChangeDependencies`, which runs after
// dependencies exist and again whenever they change — so anything put there
// needs a guard if it should only happen once.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The body of every `initState` in a file, brace-matched.
///
/// Crude, and sufficient: Dart has no unbalanced braces outside strings, and
/// nothing in this codebase writes a `{` into one near an `initState`.
Iterable<(int, String)> _initStateBodies(String source) sync* {
  final start = RegExp(r'void\s+initState\s*\(\s*\)\s*\{');
  for (final match in start.allMatches(source)) {
    var depth = 1;
    var i = match.end;
    while (i < source.length && depth > 0) {
      if (source[i] == '{') {
        depth++;
      } else if (source[i] == '}') {
        depth--;
      }
      i++;
    }
    final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
    yield (line, source.substring(match.end, i));
  }
}

void main() {
  test('no inherited scope is read from initState', () {
    // Every scope in this app is an InheritedWidget reached through a static
    // `of`, so the shape is the same everywhere and one pattern finds them all.
    final lookup = RegExp(r'\b(\w*Scope)\.of\(');
    final offenders = <String>[];

    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      for (final (line, body) in _initStateBodies(source)) {
        for (final hit in lookup.allMatches(body)) {
          offenders.add('${file.path}:$line — ${hit.group(1)}.of(context)');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'An inherited widget cannot be read before dependencies exist; '
          'Flutter asserts and the screen goes red. Move it to '
          'didChangeDependencies, with a flag if it must only run once.\n'
          '${offenders.join('\n')}',
    );
  });
}
