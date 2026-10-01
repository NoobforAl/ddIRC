import 'package:ddirc/src/rust/api/types.dart';
import 'package:ddirc/src/text/markdown.dart';
import 'package:flutter_test/flutter_test.dart';

const _plain = SpanStyle(
  bold: false,
  italic: false,
  underline: false,
  strikethrough: false,
  monospace: false,
  inverse: false,
);

List<TextSpan> _spans(String text) => [TextSpan(text: text, style: _plain)];

void main() {
  group('markdownToMirc', () {
    test('turns the inline marks into IRC formatting codes', () {
      expect(markdownToMirc('**bold**'), '\u0002bold\u0002');
      expect(markdownToMirc('__bold__'), '\u0002bold\u0002');
      expect(markdownToMirc('*it*'), '\u001Dit\u001D');
      expect(markdownToMirc('_it_'), '\u001Dit\u001D');
      expect(markdownToMirc('~~gone~~'), '\u001Egone\u001E');
      expect(
        markdownToMirc('run `make fix` now'),
        'run \u0011make fix\u0011 now',
      );
      expect(markdownToMirc('```a *b* c```'), '\u0011a *b* c\u0011');
    });

    test('leaves a line without markdown exactly as it was', () {
      for (final text in [
        'hello there',
        '2 * 3 * 4 = 24',
        'snake_case_name and other_thing',
        'a ** b',
        'file_name.txt',
        '* bullet',
      ]) {
        expect(markdownToMirc(text), text, reason: text);
      }
    });

    test('never touches a URL or what is inside code', () {
      const url = 'https://example.org/a_b_c/*x*';
      expect(markdownToMirc('see $url'), 'see $url');
      expect(markdownToMirc('`**not bold**`'), '\u0011**not bold**\u0011');
    });

    test('an escaped mark is the mark itself', () {
      expect(markdownToMirc(r'\*not italic\*'), '*not italic*');
    });

    test('marks combine', () {
      // Codes are toggles, so their order where two close together does not
      // matter; what matters is how the result reads.
      final runs = decorate(_spans('**bold *and italic***')).runs;
      expect(runs.map((r) => r.text), ['bold ', 'and italic']);
      expect(runs.map((r) => (r.style.bold, r.style.italic)), [
        (true, false),
        (true, true),
      ]);
    });
  });

  group('decorate', () {
    test('styles runs and keeps the text', () {
      final line = decorate(_spans('a **b** c'));
      expect(line.plain, 'a b c');
      expect(line.runs.map((r) => r.style.bold), [false, true, false]);
    });

    test('finds links, without their trailing punctuation', () {
      final line = decorate(_spans('see https://example.org/x. and www.a.io!'));
      final links = [
        for (final r in line.runs)
          if (r.link != null) r.link,
      ];
      expect(links, ['https://example.org/x', 'https://www.a.io']);
      expect(line.plain, 'see https://example.org/x. and www.a.io!');
    });

    test('a leading "> " is a quote', () {
      final line = decorate(_spans('> what she said'));
      expect(line.quote, isTrue);
      expect(line.plain, 'what she said');
    });

    test('with markdown off only links are found', () {
      final line = decorate(_spans('**x** https://a.b'), markdown: false);
      expect(line.plain, '**x** https://a.b');
      expect(line.runs.any((r) => r.style.bold), isFalse);
      expect(line.runs.last.link, 'https://a.b');
      expect(line.quote, isFalse);
    });

    test('an address inside code is shown, not linked', () {
      final line = decorate(_spans('`https://a.b`'));
      expect(line.runs.single.link, isNull);
      expect(line.runs.single.style.monospace, isTrue);
    });
  });
}
