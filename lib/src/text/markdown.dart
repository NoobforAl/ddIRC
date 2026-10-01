import '../rust/api/types.dart';

/// Markdown, as far as a chat line has any use for it — and no further.
///
/// People already type `**this**` for emphasis, in every client, whether or
/// not anything renders it. IRC has its own formatting, as control codes,
/// that every client *does* render. So the composer turns one into the other
/// on the way out ([markdownToMirc]), and a line that arrives with asterisks
/// someone typed by hand is drawn the way they meant it ([decorate]).
///
/// Inline marks only: **bold**, *italic* (or _italic_), ~~struck~~, `code`
/// and ```code```, plus a line that starts with `> ` drawn as a quote, and
/// links made tappable. No headings, lists or tables — those are documents,
/// and a chat line is one line.
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

/// Turn the markdown in [text] into IRC formatting codes.
///
/// Text with nothing to convert comes back unchanged — byte for byte, so a
/// line without markdown is never altered on its way to the server.
String markdownToMirc(String text) {
  if (!text.contains(RegExp(r'[*_~`\\]'))) return text;

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

  out = out
      .replaceAllMapped(_boldStars, (m) => '$_bold${m[1]}$_bold')
      .replaceAllMapped(_boldUnderscores, (m) => '$_bold${m[1]}$_bold')
      .replaceAllMapped(_strikeTildes, (m) => '$_strike${m[1]}$_strike')
      .replaceAllMapped(_italicStar, (m) => '$_italic${m[1]}$_italic')
      .replaceAllMapped(_italicUnderscore, (m) => '$_italic${m[1]}$_italic');

  return out.replaceAllMapped(
    RegExp('(\\d+)'),
    (m) => kept[int.parse(m[1]!)],
  );
}

/// One run of a decorated line: its text, its style, and where it links to.
class Decorated {
  const Decorated(this.text, this.style, {this.link});

  final String text;
  final SpanStyle style;

  /// The address to open, when this run is a link. Already given a scheme
  /// when the text had none.
  final String? link;
}

/// A line, decorated: its runs, and whether it is a quotation.
class DecoratedLine {
  const DecoratedLine(this.runs, {this.quote = false});

  final List<Decorated> runs;

  /// The line began with `> `. The marker itself is gone from [runs]; the
  /// caller draws a quote instead.
  final bool quote;

  String get plain => runs.map((r) => r.text).join();
}

/// Draw [spans] the way their author meant: markdown made into style, links
/// found, a leading `> ` made into a quote.
///
/// With [markdown] off only the links are found — a link is a link however
/// the line was written, and finding it changes nothing about its text.
DecoratedLine decorate(List<TextSpan> spans, {bool markdown = true}) {
  var source = spans;
  var quote = false;
  if (markdown && source.isNotEmpty && source.first.text.startsWith('> ')) {
    quote = true;
    source = [
      TextSpan(text: source.first.text.substring(2), style: source.first.style),
      ...source.skip(1),
    ];
  }

  final runs = <Decorated>[];
  for (final span in source) {
    final pieces = markdown
        ? _styled(markdownToMirc(span.text), span.style)
        : [Decorated(span.text, span.style)];
    for (final piece in pieces) {
      _linked(piece, runs);
    }
  }
  return DecoratedLine(runs, quote: quote);
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

/// Split [piece] around the links in it, adding the runs to [out]. Text in a
/// code span is left alone: an address quoted as code is being shown, not
/// offered.
void _linked(Decorated piece, List<Decorated> out) {
  if (piece.style.monospace) {
    out.add(piece);
    return;
  }
  var at = 0;
  for (final match in _url.allMatches(piece.text)) {
    if (match.start > at) {
      out.add(Decorated(piece.text.substring(at, match.start), piece.style));
    }
    final address = match[0]!;
    out.add(
      Decorated(
        address,
        piece.style,
        link: address.toLowerCase().startsWith('www.')
            ? 'https://$address'
            : address,
      ),
    );
    at = match.end;
  }
  if (at == 0) {
    out.add(piece);
  } else if (at < piece.text.length) {
    out.add(Decorated(piece.text.substring(at), piece.style));
  }
}
