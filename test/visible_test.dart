// The text a person is asked to approve has to be the text that happens.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/text/visible.dart';

void main() {
  group('text from an agent, as it will be sent', () {
    test('loses what would act without being seen', () {
      // CTCP, an mIRC colour, and an ANSI escape.
      expect(cleanForSending('\x01VERSION\x01'), 'VERSION');
      expect(cleanForSending('a\x0304b'), 'a04b');
      expect(cleanForSending('a\x1b[2Jb'), 'a[2Jb');
      expect(cleanForSending('a\u009B2Jb'), 'a2Jb');
    });

    test('loses what would change how it reads', () {
      expect(cleanForSending('cod\u202Efdp.exe'), 'codfdp.exe');
      expect(cleanForSending('a\u2067b\u2069c'), 'abc');
      expect(cleanForSending('a\u2028b'), 'ab');
    });

    test('loses invisible tag characters, which can spell out text', () {
      final tagged = String.fromCharCodes([0x61, 0xE0041, 0xE0042, 0x62]);
      expect(cleanForSending(tagged), 'ab');
    });

    test('blank lines cannot push the message out of view', () {
      expect(
        cleanForSending('hello\n\n \n\t\n\r\nthe real message'),
        'hello\nthe real message',
      );
    });

    test('ordinary text is left alone', () {
      const text = 'سلام‌دنیا 👨‍👩‍👧\nsecond line‏';
      expect(cleanForSending(text), text);
    });

    test('nothing but filler comes back empty', () {
      expect(cleanForSending('\x01\n\u202E\n  '), isEmpty);
    });
  });

  group('showing text someone has to decide about', () {
    test('marks what would otherwise draw nothing', () {
      expect(showHidden('a\u202Eb'), 'a⟦U+202E⟧b');
      expect(showHidden('a\u200Bb'), 'a⟦U+200B⟧b');
      expect(showHidden('a\x01b'), 'a⟦U+0001⟧b');
      expect(showHidden(String.fromCharCodes([0xE0041])), '⟦U+E0041⟧');
    });

    test('a name cannot fake a second line, and a message keeps its own', () {
      expect(showHidden('a\nb'), 'a⟦U+000A⟧b');
      expect(showHidden('a\nb', keepLines: true), 'a\nb');
    });

    test('leaves scripts and emoji that use joiners alone', () {
      const text = 'سلام‌دنیا 👨‍👩‍👧 ‏';
      expect(showHidden(text), text);
    });
  });
}
