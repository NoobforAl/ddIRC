import 'package:ddirc/src/rust/api/types.dart';
import 'package:ddirc/src/text/markdown.dart';
import 'package:ddirc/src/ui/link.dart' show linkWarnings;
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

  group('lines', () {
    test('headings, lists, tasks and rules', () {
      final h = decorate(_spans('## Release notes'));
      expect(
        (h.kind, h.level, h.plain),
        (LineKind.heading, 2, 'Release notes'),
      );

      final b = decorate(_spans('- first'));
      expect((b.kind, b.plain), (LineKind.bullet, 'first'));

      final nested = decorate(_spans('    * deeper'));
      expect((nested.kind, nested.indent), (LineKind.bullet, 2));

      final o = decorate(_spans('12. twelfth'));
      expect((o.kind, o.marker, o.plain), (LineKind.ordered, '12.', 'twelfth'));

      final done = decorate(_spans('- [x] shipped'));
      expect(
        (done.kind, done.checked, done.plain),
        (LineKind.task, true, 'shipped'),
      );

      expect(decorate(_spans('---')).kind, LineKind.rule);
      expect(decorate(_spans('***')).kind, LineKind.rule);
    });

    test('a channel name is not a heading, and arithmetic is not a list', () {
      expect(decorate(_spans('#ddirc is quiet')).kind, LineKind.text);
      expect(decorate(_spans('-5 degrees')).kind, LineKind.text);
      expect(decorate(_spans('2024 was long')).kind, LineKind.text);
    });

    test('a bullet still gets its emphasis', () {
      expect(
        markdownToMirc('* item with *stress*'),
        '* item with \u001Dstress\u001D',
      );
    });
  });

  group('links', () {
    test('a labelled link draws its label and opens its address', () {
      final line = decorate(
        _spans('read [the docs](https://example.org/a_b) now'),
      );
      expect(line.plain, 'read the docs now');
      final link = line.runs.firstWhere((r) => r.link != null);
      expect(link.text, 'the docs');
      expect(link.link, 'https://example.org/a_b');
      expect(link.label, 'the docs');
    });

    test('a styled label is still one link', () {
      final line = decorate(_spans('[**big** news](https://example.org)'));
      expect(line.plain, 'big news');
      expect(line.runs.every((r) => r.link == 'https://example.org'), isTrue);
      expect(line.runs.first.style.bold, isTrue);
    });

    test('an address in angle brackets loses the brackets', () {
      final line = decorate(_spans('see <https://example.org>'));
      expect(line.plain, 'see https://example.org');
      expect(line.runs.last.link, 'https://example.org');
    });

    test('parentheses inside an address survive', () {
      final line = decorate(
        _spans('[Rust](https://en.wikipedia.org/wiki/Rust_(language))'),
      );
      expect(
        line.runs.single.link,
        'https://en.wikipedia.org/wiki/Rust_(language)',
      );
    });

    test('a label that names another site is warned about', () {
      final uri = Uri.parse('https://evil.example/login');
      expect(linkWarnings(uri, label: 'bank.example'), isNotEmpty);
      expect(linkWarnings(uri, label: 'log in here'), isEmpty);
      expect(
        linkWarnings(
          Uri.parse('https://www.example.org'),
          label: 'example.org',
        ),
        isEmpty,
      );
      expect(linkWarnings(Uri.parse('http://example.org')), isEmpty);
      expect(linkWarnings(Uri.parse('https://xn--pple-43d.com')), hasLength(1));
      expect(
        linkWarnings(Uri.parse('https://bank.com@evil.example')),
        isNotEmpty,
      );
    });
  });

  group('blocks', () {
    test('a table with a header', () {
      final lines = [
        '| Name | Port |',
        '|:-----|-----:|',
        '| ergo | 6697 |',
        '| tor  | 9050 |',
        'after',
      ];
      final blocks = blocksOf(lines);
      expect(blocks.map((b) => (b.kind, b.start, b.end)), [
        (BlockKind.table, 0, 4),
        (BlockKind.line, 4, 5),
      ]);

      final table = parseTable([for (final l in lines.take(4)) _spans(l)]);
      expect(table.columns, 2);
      expect(table.header!.map((c) => c.plain), ['Name', 'Port']);
      expect(table.align, [CellAlign.start, CellAlign.end]);
      expect(table.rows.map((r) => r.map((c) => c.plain).toList()), [
        ['ergo', '6697'],
        ['tor', '9050'],
      ]);
    });

    test('a table without outer pipes, and an escaped pipe in a cell', () {
      final lines = [r'a | b', '---|---', r'x \| y | z'];
      expect(blocksOf(lines).single.kind, BlockKind.table);
      final table = parseTable([for (final l in lines) _spans(l)]);
      expect(table.rows.single.map((c) => c.plain), ['x | y', 'z']);
    });

    test('rows fenced in pipes, with no header, are a table too', () {
      final table = parseTable([_spans('| 1 | 2 | 3 |'), _spans('| 4 | 5 |')]);
      expect(table.header, isNull);
      expect(table.columns, 3);
      expect(table.rows.last.map((c) => c.plain), ['4', '5', '']);
    });

    test('a cell keeps its styling and links', () {
      final table = parseTable([
        _spans('| a | b |'),
        _spans('|---|---|'),
        _spans('| **bold** | [x](https://x.org) |'),
      ]);
      expect(table.rows.single[0].runs.single.style.bold, isTrue);
      expect(table.rows.single[1].runs.single.link, 'https://x.org');
    });

    test('a single pipe line is just a line', () {
      expect(blocksOf(['this | that']).single.kind, BlockKind.line);
      expect(blocksOf(['| lonely |']).single.kind, BlockKind.line);
    });

    test('a fenced code block, closed and still open', () {
      final closed = blocksOf(['```dart', 'void main() {}', '```', 'after']);
      expect(closed.first.kind, BlockKind.code);
      expect(closed.first.language, 'dart');
      expect((closed.first.start, closed.first.end), (0, 3));
      expect(closed.last.kind, BlockKind.line);

      final open = blocksOf(['```', 'still coming']);
      expect((open.single.kind, open.single.end), (BlockKind.code, 2));
    });

    test('what is inside a fence is sent as written', () {
      const text = '**bold**\n```\na *b* c\n```\n*it*';
      expect(
        markdownToMirc(text),
        '\u0002bold\u0002\n```\na *b* c\n```\n\u001Dit\u001D',
      );
    });
  });
}
