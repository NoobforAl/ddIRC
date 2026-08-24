// The committed icons are what the spec says they are.
//
// tool/make_icons.dart writes files that are then committed, which is the one
// arrangement where source and output can silently disagree: change MarkSpec,
// forget `make icons`, and every build afterwards ships the old mark. This
// re-renders from the same spec and compares bytes, so that mistake fails a
// test instead of shipping.
//
// It also pins the generator itself. The PNG and ICO writers here are hand
// rolled, and a change that broke a header or a checksum would otherwise only
// show up as a launcher icon that had quietly gone blank.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/make_icons.dart' as icons;

void main() {
  test('assets/icon/ddirc.png is the current mark', () {
    final committed = File('assets/icon/ddirc.png').readAsBytesSync();
    expect(committed, icons.png(icons.render(512), 512, 512));
  });

  test('the Windows icon is the current mark, at every size', () {
    final committed = File(
      'windows/runner/resources/app_icon.ico',
    ).readAsBytesSync();
    expect(committed.isNotEmpty, isTrue);
    // Rebuilt end to end rather than compared entry by entry: the directory
    // offsets are part of what can go wrong.
    expect(
      committed,
      icons.ico([
        for (final size in [16, 24, 32, 48, 64, 128, 256])
          icons.png(icons.render(size), size, size),
      ]),
    );
  });

  test('the Android launcher icon is the current mark', () {
    final committed = File(
      'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png',
    ).readAsBytesSync();
    expect(committed, icons.png(icons.render(192), 192, 192));
  });

  test('the icon is drawn, not scaled from one master', () {
    // The whole reason for a generator: the 16px icon is drawn at 16px. If it
    // were downscaled from a larger bitmap the strokes would go grey rather
    // than staying near the glyph colour.
    final small = icons.render(16);
    var brightest = 0;
    for (var i = 0; i < small.length; i += 4) {
      if (small[i + 3] == 255 && small[i] > brightest) brightest = small[i];
    }
    expect(brightest, greaterThan(0xE0));
  });
}
