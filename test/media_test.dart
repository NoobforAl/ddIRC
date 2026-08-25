// Tests for what happens to a file on its way out.
//
// The stripping itself is Rust and is tested there, against real photographs.
// What is tested here is the policy around it: whether it runs, what the user
// is told, and — the one that matters — that a file nothing could be removed
// from is never quietly treated as though it had been cleaned.
//
// The stripper is injected, so none of this needs the native library.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/media.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart';

final _file = Uint8List.fromList([1, 2, 3, 4]);
final _cleaned = Uint8List.fromList([1, 4]);

MediaCleaner _cleanerFor(AppSettings settings, CleanOutcome outcome) =>
    MediaCleaner(settings, strip: (_) async => outcome);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppSettings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
  });

  group('the setting', () {
    test('is on, unlike every other privacy switch here', () {
      // The logging switches decide whether to keep something the user already
      // has. This one decides whether a stranger gets the coordinates of the
      // room a photo was taken in, and a default nobody finds protects nobody.
      expect(settings.stripImageMetadata, isTrue);
    });

    test('persists when turned off', () async {
      settings.stripImageMetadata = false;
      final reloaded = await AppSettings.load();
      expect(reloaded.stripImageMetadata, isFalse);
    });
  });

  group('a file that was cleaned', () {
    late CleanedFile result;

    setUp(() async {
      result = await _cleanerFor(
        settings,
        CleanOutcome.cleaned(
          bytes: _cleaned,
          kind: 'JPEG',
          removed: [
            RemovedItem(what: 'comment', bytes: BigInt.zero),
            RemovedItem(what: 'EXIF', bytes: BigInt.zero),
          ],
        ),
      ).prepare(_file);
    });

    test('comes back as the new bytes, not the original', () async {
      expect(result.bytes, _cleaned);
      expect(result.state, CleanState.cleaned);
      expect(result.kind, 'JPEG');
    });

    test('does not need to warn anyone', () {
      // It worked. Interrupting to say so would train people to click past it.
      expect(result.carriesUnknownData, isFalse);
    });
  });

  test('what was removed is ordered largest first', () async {
    // Only one of them can be named in a caption, so it should be the one that
    // took up the most room.
    final result = await _cleanerFor(
      settings,
      CleanOutcome.cleaned(
        bytes: _cleaned,
        kind: 'JPEG',
        removed: [
          RemovedItem(what: 'comment', bytes: BigInt.from(20)),
          RemovedItem(what: 'EXIF', bytes: BigInt.from(4000)),
          RemovedItem(what: 'XMP', bytes: BigInt.from(300)),
        ],
      ),
    ).prepare(_file);

    expect(result.removed.map((r) => r.what), ['EXIF', 'XMP', 'comment']);
    expect(result.removedBytes, 4320);
    expect(result.describe(), contains('3 pieces'));
  });

  test('a file with nothing in it is not described as cleaned', () async {
    // "Cleaned" implies work was done and invites trust in the wrong place.
    final result = await _cleanerFor(
      settings,
      const CleanOutcome.alreadyClean(kind: 'PNG'),
    ).prepare(_file);

    expect(result.state, CleanState.alreadyClean);
    expect(result.bytes, _file, reason: 'the original should come back');
    expect(result.describe(), 'This PNG carried no metadata');
    expect(result.carriesUnknownData, isFalse);
  });

  group('a file nothing could be removed from', () {
    test('is sent anyway, and says so', () async {
      // Refusing to send a document because it is not a JPEG would answer a
      // question nobody asked.
      final result = await _cleanerFor(
        settings,
        const CleanOutcome.notAnImage(),
      ).prepare(_file);

      expect(result.state, CleanState.notAnImage);
      expect(result.bytes, _file);
      expect(result.describe(), contains('sent as it is'));
    });

    test('is the case worth warning about', () async {
      // This is where the protection quietly did not apply, which is exactly
      // when someone would want to know.
      for (final outcome in [
        const CleanOutcome.notAnImage(),
        const CleanOutcome.malformed(detail: 'truncated'),
      ]) {
        final result = await _cleanerFor(settings, outcome).prepare(_file);
        expect(result.carriesUnknownData, isTrue, reason: '$outcome');
      }
    });
  });

  test('a damaged image is told apart from a file that is not one', () async {
    // One means a half-copied download, the other a file picked by mistake.
    final result = await _cleanerFor(
      settings,
      const CleanOutcome.malformed(detail: 'segment runs past the end'),
    ).prepare(_file);

    expect(result.state, CleanState.damaged);
    expect(result.detail, 'segment runs past the end');
    expect(result.describe(), contains('would not open'));
  });

  group('with the setting off', () {
    test('nothing is attempted and the file is unchanged', () async {
      settings.stripImageMetadata = false;
      var called = false;
      final cleaner = MediaCleaner(
        settings,
        strip: (_) async {
          called = true;
          return const CleanOutcome.notAnImage();
        },
      );

      final result = await cleaner.prepare(_file);
      expect(called, isFalse, reason: 'the stripper should not have run');
      expect(result.state, CleanState.notAttempted);
      expect(result.bytes, _file);
    });

    test(
      'it still warns, because the file carries whatever it carried',
      () async {
        settings.stripImageMetadata = false;
        final result = await _cleanerFor(
          settings,
          const CleanOutcome.notAnImage(),
        ).prepare(_file);
        expect(result.carriesUnknownData, isTrue);
        expect(result.describe(), contains('switched off'));
      },
    );
  });

  test('a stripper that throws does not stop the file being sent', () async {
    // A bug in the cleaner must not cost someone their message. It must also
    // not silently claim the file was cleaned.
    final cleaner = MediaCleaner(
      settings,
      strip: (_) async => throw StateError('the native library exploded'),
    );

    final result = await cleaner.prepare(_file);
    expect(result.bytes, _file);
    expect(result.state, CleanState.damaged);
    expect(result.carriesUnknownData, isTrue);
  });
}
