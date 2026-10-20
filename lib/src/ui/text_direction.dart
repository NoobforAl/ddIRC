import 'package:flutter/painting.dart';

/// Which way a piece of text should run, by its first strong character.
///
/// The rule browsers apply to `dir="auto"`, and the one a chat needs: each
/// message is judged on its own words, not on the app's language. Without it a
/// Persian or Arabic message is laid out left to right, so it is flush left in
/// its bubble and anything Latin mixed into it lands at the wrong end of the
/// line.
///
/// Only *strong* characters decide — letters that have a direction of their
/// own. Digits, punctuation, spaces and emoji are neutral and are skipped, so
/// `"123 — سلام"` is right to left and `"سلام — hello"` is too, because the
/// first thing with an opinion is what the line starts with.
///
/// Null when there is nothing strong at all (`"👍"`, `"..."`, `"42"`); the
/// caller keeps whatever direction it already has rather than being told to
/// pick one.
TextDirection? strongDirectionOf(String text) {
  for (final rune in text.runes) {
    // Explicit marks first: they exist to say exactly this.
    if (rune == 0x200F) return TextDirection.rtl; // RLM
    if (rune == 0x200E) return TextDirection.ltr; // LRM
    if (_isRtlLetter(rune)) return TextDirection.rtl;
    if (_isLetter(rune)) return TextDirection.ltr;
  }
  return null;
}

/// [strongDirectionOf], with a fallback for text that has no opinion.
TextDirection directionOfText(
  String text, {
  TextDirection fallback = TextDirection.ltr,
}) => strongDirectionOf(text) ?? fallback;

/// The scripts written right to left: Hebrew, Arabic and its supplements and
/// presentation forms, Syriac, Thaana and N'Ko.
bool _isRtlLetter(int r) =>
    (r >= 0x0590 && r <= 0x08FF) ||
    (r >= 0xFB1D && r <= 0xFDFF) ||
    (r >= 0xFE70 && r <= 0xFEFF) ||
    (r >= 0x10800 && r <= 0x10FFF) ||
    (r >= 0x1E800 && r <= 0x1EFFF);

final RegExp _letter = RegExp(r'\p{L}', unicode: true);

bool _isLetter(int r) {
  // ASCII is nearly all of what a chat holds, and a table lookup is cheaper
  // than a regular expression for it.
  if (r < 0x80) {
    return (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A);
  }
  return _letter.hasMatch(String.fromCharCode(r));
}
