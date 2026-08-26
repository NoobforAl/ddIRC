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

  test('the Android launch-screen mark is the current mark', () {
    // The one icon nobody looks at during development, because it is only on
    // screen while the app is starting — which is exactly when a stale or
    // missing one is least likely to be noticed and most likely to be seen.
    final committed = File(
      'android/app/src/main/res/drawable-xxxhdpi/ic_splash.png',
    ).readAsBytesSync();
    expect(committed, icons.png(icons.render(72 * 4), 72 * 4, 72 * 4));
  });

  test('the macOS icon set is the current mark', () {
    final committed = File(
      'macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_512.png',
    ).readAsBytesSync();
    expect(committed, icons.macIcon(512));
  });

  test('the iOS icon set is the current mark, and has no alpha', () {
    final committed = File(
      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
    ).readAsBytesSync();
    expect(committed, icons.iosIcon(1024));
    // Colour type 2 is RGB. An iOS icon with an alpha channel is rejected on
    // upload, and the corners are masked by the system anyway.
    expect(committed[25], 2);
  });

  test('the Windows tray icon is the current mark, at the tray sizes', () {
    final committed = File('assets/tray/tray.ico').readAsBytesSync();
    expect(
      committed,
      icons.ico([
        // 16 at 100% scaling, then 125%, 150% and 200%. Windows picks from
        // the file rather than resizing, so a missing size is a blurred tray
        // icon — which is the kind of fault nobody bothers to report.
        for (final size in [16, 20, 24, 32])
          icons.png(icons.render(size), size, size),
      ]),
    );
  });

  test('the Linux tray icon is the current mark', () {
    final committed = File('assets/tray/tray.png').readAsBytesSync();
    expect(committed, icons.png(icons.render(64), 64, 64));
  });

  group('the macOS menu bar template', () {
    test('is the current mark', () {
      final committed = File('assets/tray/tray_template.png').readAsBytesSync();
      expect(committed, icons.trayTemplate(44));
    });

    test('is one ink on transparency, which is what a template means', () {
      // The menu bar recolours a template from its alpha alone and throws the
      // colour away. An image with the mark's own field and near-white glyph
      // in it comes out as a filled blob on a dark bar and a different blob on
      // a light one, so every opaque pixel here has to be the same ink.
      final pixels = icons.render(
        44,
        field: false,
        scale: 1.5,
        glyph: 0xFF000000,
      );
      var opaque = 0;
      for (var i = 0; i < pixels.length; i += 4) {
        if (pixels[i + 3] == 0) continue;
        opaque++;
        expect(pixels[i], 0, reason: 'red at byte $i');
        expect(pixels[i + 1], 0, reason: 'green at byte $i');
        expect(pixels[i + 2], 0, reason: 'blue at byte $i');
      }
      // And it must not be an empty image, which would pass the above.
      expect(opaque, greaterThan(0));
    });

    test('fills the slot, rather than sitting in it as a speck', () {
      // Without the field behind it the glyph alone occupies just over half
      // the canvas, which in a 22-point menu bar slot is unreadable. It is
      // drawn larger to compensate, and this is the assertion that notices if
      // that compensation is ever dropped.
      final pixels = icons.trayTemplate(44);
      expect(pixels, isNot(icons.png(icons.render(44, field: false), 44, 44)));
    });
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
