import 'package:ddirc/src/ui/text_direction.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('strongDirectionOf', () {
    test('Latin text is left to right', () {
      expect(strongDirectionOf('hello world'), TextDirection.ltr);
    });

    test('Persian, Arabic and Hebrew are right to left', () {
      expect(strongDirectionOf('سلام دنیا'), TextDirection.rtl);
      expect(strongDirectionOf('مرحبا'), TextDirection.rtl);
      expect(strongDirectionOf('שלום'), TextDirection.rtl);
    });

    test('the first strong character decides, not the majority', () {
      expect(strongDirectionOf('سلام hello world and more'), TextDirection.rtl);
      expect(strongDirectionOf('hello سلام سلام سلام'), TextDirection.ltr);
    });

    test('neutral characters at the start are skipped', () {
      expect(strongDirectionOf('123 — سلام'), TextDirection.rtl);
      expect(strongDirectionOf('"... " hello'), TextDirection.ltr);
      expect(strongDirectionOf('👍 سلام'), TextDirection.rtl);
      expect(strongDirectionOf('• hello'), TextDirection.ltr);
    });

    test('non-Latin left-to-right scripts are left to right', () {
      expect(strongDirectionOf('привет'), TextDirection.ltr);
      expect(strongDirectionOf('こんにちは'), TextDirection.ltr);
    });

    test('text with nothing strong has no direction of its own', () {
      expect(strongDirectionOf(''), isNull);
      expect(strongDirectionOf('42'), isNull);
      expect(strongDirectionOf('👍🎉'), isNull);
      expect(strongDirectionOf('... ?!'), isNull);
    });

    test('explicit direction marks win', () {
      expect(strongDirectionOf('‏hello'), TextDirection.rtl);
      expect(strongDirectionOf('‎سلام'), TextDirection.ltr);
    });

    test('Arabic presentation forms count', () {
      expect(strongDirectionOf('ﺍ'), TextDirection.rtl);
    });
  });

  group('directionOfText', () {
    test('falls back when there is nothing strong', () {
      expect(directionOfText('42'), TextDirection.ltr);
      expect(
        directionOfText('42', fallback: TextDirection.rtl),
        TextDirection.rtl,
      );
    });

    test('ignores the fallback when there is something strong', () {
      expect(
        directionOfText('hello', fallback: TextDirection.rtl),
        TextDirection.ltr,
      );
    });
  });
}
