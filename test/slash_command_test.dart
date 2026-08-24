// The composer offers these and the parser accepts them. This file exists to
// keep those two facts the same fact — a suggestion the user picks and then
// gets "unknown command" for is the specific failure worth a test.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/session.dart';

void main() {
  test('every offered command parses back', () {
    for (final command in SlashCommand.values) {
      expect(
        SlashCommand.parse(command.name),
        command,
        reason: '/${command.name} is offered but not accepted',
      );
    }
  });

  test('an empty prefix offers everything, in declaration order', () {
    expect(SlashCommand.matching(''), SlashCommand.values);
  });

  test('a prefix narrows without reordering', () {
    expect(SlashCommand.matching('m'), [SlashCommand.msg, SlashCommand.me]);
    expect(SlashCommand.matching('me'), [SlashCommand.me]);
    expect(SlashCommand.matching('zzz'), isEmpty);
  });

  test('matching is case-insensitive, since typing /JOIN is not an error', () {
    expect(SlashCommand.matching('JO'), [SlashCommand.join]);
  });

  test('unknown names parse to null rather than a lookalike', () {
    expect(SlashCommand.parse('joi'), isNull);
    expect(SlashCommand.parse(''), isNull);
  });

  test('usage lines carry the slash and the argument shape', () {
    expect(SlashCommand.msg.usageLine, '/msg <nick> <message>');
    expect(SlashCommand.part.usageLine, '/part [reason]');
  });
}
