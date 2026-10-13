import '../rust/api/types.dart';

/// Markdown, as far as a chat has any use for it.
///
/// People already type `**this**` for emphasis, in every client, whether or
/// not anything renders it. IRC has its own formatting, as control codes,
/// that every client *does* render. So the composer turns one into the other
/// on the way out ([markdownToMirc]), and a line that arrives with asterisks
/// someone typed by hand is drawn the way they meant it ([decorate]).
///
/// Inline: **bold**, *italic* (or _italic_), ~~struck~~, `code` and
/// ```code```, `[a label](https://…)` and `<https://…>` links, and bare links
/// made tappable.
///
/// Per line: `# headings`, `- bullets` (and `*`, `+`), `1. numbered` items,
/// `- [ ] tasks`, `> quotes` and `---` rules.
///
/// Across lines ([blocksOf]): a fenced ```` ``` ```` code block, and a
/// `| table |`. IRC carries one line per message, so a table or a block of
/// code arrives as several messages; they are put back together where they
/// sit next to each other in one person's bubble.
///
/// What is never touched: anything inside a code span, anything inside a URL
/// (`https://example.org/a_b_c` is not italic), a mark with a space just
/// inside it (`2 * 3 * 4` is arithmetic), an underscore inside a word
/// (`snake_case_name`), and anything escaped with a backslash.

const _bold = '\u0002';
const _italic = '\u001D';
const _strike = '\u001E';
const _mono = '\u0011';

/// Links worth making tappable: an explicit scheme, or a bare `www.` host.
/// Trailing punctuation is left out of the link, because a sentence that ends
/// with a URL ends with a full stop that is not part of it.
final _url = RegExp(
  r'''(?:https?://|www\.)[^\s<>"']+[^\s<>"'.,;:!?)\]}]''',
  caseSensitive: false,
);

/// `[label](address)`, with an optional `"title"` after the address, which is
/// dropped. One level of parentheses is allowed inside the address, because
/// Wikipedia.
final _labelled = RegExp(
  r'''\[([^\[\]\n]+)\]\(\s*<?((?:https?://|www\.)[^\s()<>]*(?:\([^\s()<>]*\)[^\s()<>]*)*)>?(?:\s+"[^"]*")?\s*\)''',
  caseSensitive: false,
);

/// `<https://example.org>` — a link with its brackets, which are not part of
/// what is drawn.
final _angled = RegExp(r'<((?:https?://)[^\s<>]+)>', caseSensitive: false);

final _code = RegExp(r'```(.+?)```|`([^`]+)`');

final _escape = RegExp(r'\\([*_~`\\])');

// Each requires something other than a space just inside both marks, which is
// what separates emphasis from a stray symbol.
final _boldStars = RegExp(r'\*\*(?=\S)(.+?)(?<=\S)\*\*');
final _boldUnderscores = RegExp(
  r'(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])',
  unicode: true,
);
final _strikeTildes = RegExp(r'~~(?=\S)(.+?)(?<=\S)~~');
final _italicStar = RegExp(
  r'(?<![*\p{L}\p{N}])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\p{L}\p{N}])',
  unicode: true,
);
final _italicUnderscore = RegExp(
  r'(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])',
  unicode: true,
);

// Line markers. Each is only looked for at the very start of a line.
final _heading = RegExp(r'^(#{1,6})[ \t]+');
final _task = RegExp(r'^([ \t]*)[-*+][ \t]+\[([ xX])\][ \t]+');
final _bullet = RegExp(r'^([ \t]*)[-*+][ \t]+(?=\S)');
final _ordered = RegExp(r'^([ \t]*)(\d{1,9})([.)])[ \t]+(?=\S)');
final _rule = RegExp(r'^[ \t]*([-*_])(?:[ \t]*\1){2,}[ \t]*$');
final _fence = RegExp(r'^[ \t]*(```|~~~)[ \t]*([\w+#.-]*)[ \t]*$');

/// Turn the markdown in [text] into IRC formatting codes.
///
/// Text with nothing to convert comes back unchanged — byte for byte, so a
/// line without markdown is never altered on its way to the server. Several
/// lines are converted one at a time, and the lines of a fenced code block not
/// at all: they are code, and code is sent as it was written.
String markdownToMirc(String text) {
  if (!text.contains(RegExp(r'[*_~`\\]'))) return text;
  if (!text.contains('\n')) return _lineToMirc(text);

  final out = <String>[];
  String? fence;
  for (final line in text.split('\n')) {
    final open = _fence.firstMatch(line.trimRight());
    if (fence == null && open != null) {
      fence = open[1];
      out.add(line);
    } else if (fence != null) {
      if (line.trim() == fence) fence = null;
      out.add(line);
    } else {
      out.add(_lineToMirc(line));
    }
  }
  return out.join('\n');
}

String _lineToMirc(String text) {
  if (!text.contains(RegExp(r'[*_~`\\]'))) return text;
  // A rule is three marks and nothing else. Left alone, `***` would be read as
  // an empty pair of emphasis marks around a star.
  if (_rule.hasMatch(text)) return text;

  // Code spans and URLs are cut out first and put back last, untouched: what
  // is inside them is literal, and that is the whole point of both.
  final kept = <String>[];
  String keep(String literal) {
    kept.add(literal);
    return '${kept.length - 1}';
  }

  var out = text.replaceAllMapped(
    _code,
    (m) => keep('$_mono${m[1] ?? m[2]}$_mono'),
  );
  out = out.replaceAllMapped(_url, (m) => keep(m[0]!));
  out = out.replaceAllMapped(_escape, (m) => keep(m[1]!));
  // A list marker at the start is not the opening half of an italic.
  var lead = '';
  final bullet = RegExp(r'^[ \t]*[-*+][ \t]+').firstMatch(out);
  if (bullet != null) {
    lead = bullet[0]!;
    out = out.substring(lead.length);
  }

  out = out
      .replaceAllMapped(_boldStars, (m) => '$_bold${m[1]}$_bold')
      .replaceAllMapped(_boldUnderscores, (m) => '$_bold${m[1]}$_bold')
      .replaceAllMapped(_strikeTildes, (m) => '$_strike${m[1]}$_strike')
      .replaceAllMapped(_italicStar, (m) => '$_italic${m[1]}$_italic')
      .replaceAllMapped(_italicUnderscore, (m) => '$_italic${m[1]}$_italic');

  return '$lead$out'.replaceAllMapped(
    RegExp('(\\d+)'),
    (m) => kept[int.parse(m[1]!)],
  );
}

/// One run of a decorated line: its text, its style, and where it links to.
class Decorated {
  const Decorated(this.text, this.style, {this.link, this.label});

  final String text;
  final SpanStyle style;

  /// The address to open, when this run is a link. Already given a scheme
  /// when the text had none.
  final String? link;

  /// The whole of what the link was drawn as, when it was written as
  /// `[label](address)` — which can say anything at all, including another
  /// address. Null when the text drawn *is* the address.
  final String? label;
}

/// What a line is, beyond its words.
enum LineKind { text, heading, bullet, ordered, task, quote, rule }

/// A line, decorated: its runs, and what kind of line it is.
class DecoratedLine {
  const DecoratedLine(
    this.runs, {
    this.kind = LineKind.text,
    this.level = 0,
    this.indent = 0,
    this.marker,
    this.checked = false,
  });

  final List<Decorated> runs;
  final LineKind kind;

  /// A heading's level, 1 to 6.
  final int level;

  /// How far a list item is nested, from its leading spaces.
  final int indent;

  /// A numbered item's number, as written (`3.` or `3)`).
  final String? marker;

  /// A task that is ticked.
  final bool checked;

  /// The line began with `> `. The marker itself is gone from [runs]; the
  /// caller draws a quote instead.
  bool get quote => kind == LineKind.quote;

  bool get isList =>
      kind == LineKind.bullet ||
      kind == LineKind.ordered ||
      kind == LineKind.task;

  String get plain => runs.map((r) => r.text).join();
}

/// Draw [spans] the way their author meant: markdown made into style, links
/// found, a leading marker made into a heading, a list item or a quote.
///
/// With [markdown] off only the bare links are found — a link is a link
/// however the line was written, and finding it changes nothing about its
/// text. With [inline] the line is a piece of something larger (a table
/// cell), and its start is not looked at for markers.
DecoratedLine decorate(
  List<TextSpan> spans, {
  bool markdown = true,
  bool inline = false,
}) {
  if (!markdown) {
    return DecoratedLine(
      _linked([for (final s in spans) Decorated(s.text, s.style)], false),
    );
  }

  var source = spans;
  var kind = LineKind.text;
  var level = 0;
  var indent = 0;
  String? marker;
  var checked = false;

  if (!inline && source.isNotEmpty) {
    final plain = source.map((s) => s.text).join();
    if (_rule.hasMatch(plain)) {
      return const DecoratedLine([], kind: LineKind.rule);
    }
    final first = source.first.text;
    var cut = 0;
    if (first.startsWith('> ')) {
      kind = LineKind.quote;
      cut = 2;
    } else if (_heading.firstMatch(first) case final m?) {
      kind = LineKind.heading;
      level = m[1]!.length;
      cut = m.end;
    } else if (_task.firstMatch(first) case final m?) {
      kind = LineKind.task;
      indent = _depth(m[1]!);
      checked = m[2] != ' ';
      cut = m.end;
    } else if (_bullet.firstMatch(first) case final m?) {
      kind = LineKind.bullet;
      indent = _depth(m[1]!);
      cut = m.end;
    } else if (_ordered.firstMatch(first) case final m?) {
      kind = LineKind.ordered;
      indent = _depth(m[1]!);
      marker = '${m[2]}${m[3]}';
      cut = m.end;
    }
    if (cut > 0) {
      source = [
        TextSpan(text: first.substring(cut), style: source.first.style),
        ...source.skip(1),
      ];
    }
  }

  final styled = <Decorated>[
    for (final span in source)
      ..._styled(markdownToMirc(span.text), span.style),
  ];
  return DecoratedLine(
    _linked(styled, true),
    kind: kind,
    level: level,
    indent: indent,
    marker: marker,
    checked: checked,
  );
}

int _depth(String lead) {
  final width = lead.replaceAll('\t', '    ').length;
  return (width ~/ 2).clamp(0, 4);
}

/// Walk text carrying the codes [markdownToMirc] put in, and split it where
/// the style changes. Incoming text never carries control codes of its own —
/// the core strips them before a line reaches the app — so every code here
/// is one this file added.
List<Decorated> _styled(String text, SpanStyle base) {
  if (!text.contains(RegExp('[$_bold$_italic$_strike$_mono]'))) {
    return [Decorated(text, base)];
  }
  final out = <Decorated>[];
  var bold = base.bold;
  var italic = base.italic;
  var strike = base.strikethrough;
  var mono = base.monospace;
  final buffer = StringBuffer();
  void emit() {
    if (buffer.isEmpty) return;
    out.add(
      Decorated(
        buffer.toString(),
        SpanStyle(
          bold: bold,
          italic: italic,
          underline: base.underline,
          strikethrough: strike,
          monospace: mono,
          inverse: base.inverse,
          fg: base.fg,
          bg: base.bg,
        ),
      ),
    );
    buffer.clear();
  }

  for (final char in text.split('')) {
    switch (char) {
      case _bold:
        emit();
        bold = !bold;
      case _italic:
        emit();
        italic = !italic;
      case _strike:
        emit();
        strike = !strike;
      case _mono:
        emit();
        mono = !mono;
      default:
        buffer.write(char);
    }
  }
  emit();
  return out;
}

/// Find the links in a styled line and mark them, dropping what is markup
/// rather than text: the brackets and the address of a `[label](address)`,
/// and the angle brackets around a `<address>`.
///
/// Done over the whole line rather than run by run, because styling splits a
/// line into runs and a label is often styled: `[**this**](…)` is three runs
/// by the time it gets here.
///
/// Text in a code span is left alone: an address quoted as code is being
/// shown, not offered.
List<Decorated> _linked(List<Decorated> runs, bool markdown) {
  final plain = runs.map((r) => r.text).join();
  if (plain.isEmpty) return runs;

  // Which run each character came from, to tell code from prose.
  final owner = List<int>.filled(plain.length, 0);
  var at = 0;
  for (var r = 0; r < runs.length; r++) {
    owner.fillRange(at, at + runs[r].text.length, r);
    at += runs[r].text.length;
  }
  bool code(int i) => runs[owner[i]].style.monospace;

  final drop = List<bool>.filled(plain.length, false);
  final link = List<String?>.filled(plain.length, null);
  final label = List<String?>.filled(plain.length, null);
  final taken = List<bool>.filled(plain.length, false);

  String address(String found) =>
      found.toLowerCase().startsWith('www.') ? 'https://$found' : found;

  if (markdown) {
    for (final m in _labelled.allMatches(plain)) {
      if (code(m.start)) continue;
      final text = m[1]!;
      final from = m.start + 1;
      final to = from + text.length;
      final target = address(m[2]!);
      for (var i = m.start; i < m.end; i++) {
        taken[i] = true;
        if (i >= from && i < to) {
          link[i] = target;
          label[i] = text;
        } else {
          drop[i] = true;
        }
      }
    }
    for (final m in _angled.allMatches(plain)) {
      if (code(m.start) || taken[m.start]) continue;
      for (var i = m.start; i < m.end; i++) {
        taken[i] = true;
        if (i == m.start || i == m.end - 1) {
          drop[i] = true;
        } else {
          link[i] = m[1];
        }
      }
    }
  }

  for (final m in _url.allMatches(plain)) {
    if (code(m.start) || taken.sublist(m.start, m.end).contains(true)) {
      continue;
    }
    final target = address(m[0]!);
    for (var i = m.start; i < m.end; i++) {
      link[i] = target;
    }
  }

  if (!drop.contains(true) && link.every((l) => l == null)) return runs;

  final out = <Decorated>[];
  at = 0;
  for (final run in runs) {
    var start = at;
    void emit(int end) {
      if (end > start) {
        out.add(
          Decorated(
            plain.substring(start, end),
            run.style,
            link: link[start],
            label: label[start],
          ),
        );
      }
    }

    final end = at + run.text.length;
    for (var i = at; i < end; i++) {
      if (drop[i]) {
        emit(i);
        start = i + 1;
      } else if (i > start && link[i] != link[i - 1]) {
        emit(i);
        start = i;
      }
    }
    emit(end);
    at = end;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Blocks: what spans several lines.

/// What a stretch of consecutive lines is drawn as.
enum BlockKind { line, table, code }

/// Lines [start] to [end] (exclusive) of a bubble, drawn as one [kind].
class MdBlock {
  const MdBlock(this.kind, this.start, this.end, {this.language});

  final BlockKind kind;
  final int start;
  final int end;

  /// What a code block says it is written in, after its opening fence.
  final String? language;

  int get length => end - start;
}

/// Split one person's consecutive lines, as plain text, into what is drawn as
/// one piece: a fenced code block, a table, or a line on its own.
///
/// A fence with no end yet runs to the last line: the rest of it may still be
/// on its way, a message at a time.
List<MdBlock> blocksOf(List<String> lines) {
  final out = <MdBlock>[];
  var i = 0;
  while (i < lines.length) {
    final open = _fence.firstMatch(lines[i].trimRight());
    if (open != null) {
      final mark = open[1]!;
      var j = i + 1;
      while (j < lines.length && lines[j].trim() != mark) {
        j++;
      }
      final end = j < lines.length ? j + 1 : j;
      final language = open[2]!;
      out.add(
        MdBlock(
          BlockKind.code,
          i,
          end,
          language: language.isEmpty ? null : language,
        ),
      );
      i = end;
      continue;
    }

    // A header, a `|---|` line under it, and rows: a table the way GitHub
    // writes one.
    if (i + 1 < lines.length &&
        _cells(lines[i]) != null &&
        isTableSeparator(lines[i + 1])) {
      var j = i + 2;
      while (j < lines.length &&
          _cells(lines[j]) != null &&
          !isTableSeparator(lines[j]) &&
          _fence.firstMatch(lines[j].trimRight()) == null) {
        j++;
      }
      out.add(MdBlock(BlockKind.table, i, j));
      i = j;
      continue;
    }

    // Rows with no header: two or more lines fenced in pipes at both ends.
    // Plenty of bots draw their tables that way.
    if (_fenced(lines[i])) {
      var j = i + 1;
      while (j < lines.length && _fenced(lines[j])) {
        j++;
      }
      if (j - i >= 2) {
        out.add(MdBlock(BlockKind.table, i, j));
        i = j;
        continue;
      }
    }

    out.add(MdBlock(BlockKind.line, i, i + 1));
    i++;
  }
  return out;
}

/// Whether [line] could be a row of a table that is already going: is it
/// marked out with pipes. Used to keep a table that straddles a minute in one
/// bubble.
bool looksLikeTableRow(String line) => _cells(line) != null;

/// Whether [line] opens or closes a fenced code block.
bool isFenceLine(String line) => _fence.hasMatch(line.trimRight());

bool _fenced(String line) {
  final t = line.trim();
  return t.length >= 3 &&
      t.startsWith('|') &&
      t.endsWith('|') &&
      (_cells(line)?.length ?? 0) >= 2;
}

/// `|---|:--:|---:|`, or the same without the outer pipes.
bool isTableSeparator(String line) {
  final cells = _cells(line);
  if (cells == null) return false;
  return cells.every((c) => RegExp(r'^\s*:?-+:?\s*$').hasMatch(c));
}

/// The cells of a row, as text, or null when it has no pipe to split on.
List<String>? _cells(String line) {
  final t = line.trim();
  if (!_hasPipe(t)) return null;
  final cells = _splitPipes(t);
  if (t.startsWith('|')) cells.removeAt(0);
  if (t.endsWith('|') && !t.endsWith(r'\|') && cells.isNotEmpty) {
    cells.removeLast();
  }
  return cells.isEmpty ? null : cells;
}

bool _hasPipe(String text) {
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '|' && (i == 0 || text[i - 1] != r'\')) return true;
  }
  return false;
}

List<String> _splitPipes(String text) {
  final out = <String>[];
  final cell = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == r'\' && i + 1 < text.length && text[i + 1] == '|') {
      cell.write('|');
      i++;
    } else if (c == '|') {
      out.add(cell.toString());
      cell.clear();
    } else {
      cell.write(c);
    }
  }
  out.add(cell.toString());
  return out;
}

/// How a column lines up, from the colons in its separator.
enum CellAlign { start, center, end }

/// A table, ready to draw.
class MdTable {
  const MdTable({required this.align, required this.rows, this.header});

  final List<CellAlign> align;

  /// The first row, when the table has a `|---|` line under it.
  final List<DecoratedLine>? header;
  final List<List<DecoratedLine>> rows;

  int get columns => align.length;
}

/// Read the lines of a [BlockKind.table] block into cells.
///
/// Works on the styled spans rather than the plain text, so a cell keeps
/// whatever bold or colour the sender gave it.
MdTable parseTable(List<List<TextSpan>> lines, {bool markdown = true}) {
  final plain = [for (final l in lines) l.map((s) => s.text).join()];
  final hasHeader = lines.length >= 2 && isTableSeparator(plain[1]);

  List<DecoratedLine> row(List<TextSpan> spans) => [
    for (final cell in _splitSpans(spans))
      decorate(cell, markdown: markdown, inline: true),
  ];

  final header = hasHeader ? row(lines[0]) : null;
  final body = [
    for (var i = hasHeader ? 2 : 0; i < lines.length; i++) row(lines[i]),
  ];

  var columns = header?.length ?? 0;
  for (final r in body) {
    if (r.length > columns && header == null) columns = r.length;
  }
  if (columns == 0) columns = 1;

  final align = List.filled(columns, CellAlign.start);
  if (hasHeader) {
    final marks = _cells(plain[1])!;
    for (var c = 0; c < columns && c < marks.length; c++) {
      final m = marks[c].trim();
      align[c] = m.startsWith(':') && m.endsWith(':')
          ? CellAlign.center
          : m.endsWith(':')
          ? CellAlign.end
          : CellAlign.start;
    }
  }

  List<DecoratedLine> fit(List<DecoratedLine> r) => [
    for (var c = 0; c < columns; c++)
      c < r.length ? r[c] : const DecoratedLine([]),
  ];

  return MdTable(
    align: align,
    header: header == null ? null : fit(header),
    rows: [for (final r in body) fit(r)],
  );
}

/// Split a row's spans into its cells' spans, at every pipe that is not
/// escaped, and trim each cell.
List<List<TextSpan>> _splitSpans(List<TextSpan> spans) {
  final cells = <List<TextSpan>>[[]];
  for (final span in spans) {
    final text = span.text;
    final piece = StringBuffer();
    void flush() {
      if (piece.isNotEmpty) {
        cells.last.add(TextSpan(text: piece.toString(), style: span.style));
        piece.clear();
      }
    }

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (c == r'\' && i + 1 < text.length && text[i + 1] == '|') {
        piece.write('|');
        i++;
      } else if (c == '|') {
        flush();
        cells.add([]);
      } else {
        piece.write(c);
      }
    }
    flush();
  }

  final plain = spans.map((s) => s.text).join().trim();
  if (plain.startsWith('|') && cells.isNotEmpty) cells.removeAt(0);
  if (plain.endsWith('|') && !plain.endsWith(r'\|') && cells.isNotEmpty) {
    cells.removeLast();
  }
  return [for (final c in cells) _trim(c)];
}

List<TextSpan> _trim(List<TextSpan> spans) {
  final out = [...spans];
  while (out.isNotEmpty && out.first.text.trim().isEmpty) {
    out.removeAt(0);
  }
  while (out.isNotEmpty && out.last.text.trim().isEmpty) {
    out.removeLast();
  }
  if (out.isEmpty) return out;
  out[0] = TextSpan(text: out[0].text.trimLeft(), style: out[0].style);
  final last = out.length - 1;
  out[last] = TextSpan(
    text: out[last].text.trimRight(),
    style: out[last].style,
  );
  return out;
}
