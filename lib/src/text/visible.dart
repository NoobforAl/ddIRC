/// Making text that decides something safe to read.
///
/// A person agreeing to something has to see what they are agreeing to. Text from
/// somebody else can hold characters that draw nothing, or that make what is
/// drawn read in a different order from what it is, and on an approval sheet or
/// an import screen that is the difference between consent and a trick.
library;

/// What the core removes from text it shows, plus Unicode's invisible tag
/// characters, which spell out text no one can see. Newline is handled apart.
final _unsendable = RegExp(
  r'[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u2028-\u202E\u2066-\u2069'
  r'\u{E0000}-\u{E007F}]',
  unicode: true,
);

/// [_unsendable] and the characters that draw nothing. Joiners and direction
/// marks are not here: emoji and right-to-left scripts use them in ordinary text,
/// and they cannot hide anything.
final _hidden = RegExp(
  r'[\u0000-\u0009\u000B-\u001F\u007F-\u009F\u00AD\u200B\u2028-\u202E'
  r'\u2060-\u2064\u2066-\u2069\uFEFF\u{E0000}-\u{E007F}]',
  unicode: true,
);

/// Text with anything invisible drawn as its code, such as `⟦U+202E⟧`.
///
/// For showing and never for sending: the point is that what is on screen
/// differs from the string exactly where the string would have misled.
String showHidden(String text, {bool keepLines = false}) {
  final marked = text.replaceAllMapped(_hidden, (match) {
    final code = match[0]!.runes.single;
    return '⟦U+${code.toRadixString(16).toUpperCase().padLeft(4, '0')}⟧';
  });
  return keepLines ? marked : marked.replaceAll('\n', '⟦U+000A⟧');
}

/// Text from an agent, as it will really be sent.
///
/// Done before the approval sheet rather than after, so that what is read there
/// is what goes out. Without it the two differ in the ways that matter: `\x01`
/// turns a line into a CTCP request nobody sees, and blank lines, which IRC drops
/// when sending, can push the real message out of view below an innocent first
/// line. An agent has no use for formatting codes either, since it writes text.
String cleanForSending(String text) => text
    .replaceAll(RegExp(r'\r\n?'), '\n')
    .replaceAll(_unsendable, '')
    .split('\n')
    .where((line) => line.trim().isNotEmpty)
    .join('\n');
