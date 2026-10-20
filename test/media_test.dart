// Tests for what happens to a file on its way out.
//
// The stripping itself is Rust and is tested there, against real photographs.
// What is tested here is the policy around it: whether it runs, what the user
// is told, and — the one that matters — that a file nothing could be removed
// from is never quietly treated as though it had been cleaned.
//
// The stripper is injected, so none of this needs the native library.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/media.dart';
import 'package:ddirc/src/model/settings.dart';
import 'package:ddirc/src/rust/api/types.dart';
import 'package:ddirc/src/ui/send_file_sheet.dart';

final _file = Uint8List.fromList([1, 2, 3, 4]);
final _cleaned = Uint8List.fromList([1, 4]);

MediaCleaner _cleanerFor(AppSettings settings, CleanOutcome outcome) =>
    MediaCleaner(settings, strip: (_) async => outcome);

void main() {
  largeFileTests();
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

// Attaching a file must not cost memory in proportion to the file.
//
// It used to read the whole of whatever was picked, then hand every byte across
// the FFI to a cleaner that rewrites four kinds of image. Picking a 1.5 GB
// archive took the window to 4.8 GB of memory and "not responding", and on a
// phone would have ended the app. A file that is not an image has nothing to
// clean, and the first sixteen bytes say whether it is one.
void largeFileTests() {
  group('attaching a file', () {
    late AppSettings settings;
    late Directory dir;
    var stripped = 0;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load();
      dir = Directory.systemTemp.createTempSync('ddirc-attach-');
      stripped = 0;
    });
    tearDown(() => dir.deleteSync(recursive: true));

    MediaCleaner cleaner() => MediaCleaner(
      settings,
      strip: (bytes) async {
        stripped++;
        return CleanOutcome.alreadyClean(kind: 'JPEG');
      },
    );

    File write(String name, List<int> head, {int size = 0}) {
      final file = File('${dir.path}${Platform.pathSeparator}$name');
      final raf = file.openSync(mode: FileMode.write);
      raf.writeFromSync(head);
      if (size > head.length) raf.truncateSync(size);
      raf.closeSync();
      return file;
    }

    const jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0x10, 0x4A, 0x46, 0x49, 0x46, 0];

    test('recognises the four formats by their signature', () {
      bool is_(List<int> b) =>
          MediaCleaner.looksLikeImage(Uint8List.fromList(b));
      expect(is_(jpeg), isTrue);
      expect(
        is_([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]),
        isTrue,
      );
      expect(is_('GIF89a....'.codeUnits), isTrue);
      expect(is_('GIF87a....'.codeUnits), isTrue);
      expect(
        is_([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WEBP'.codeUnits]),
        isTrue,
      );
    });

    test('and does not mistake anything else for one', () {
      bool is_(List<int> b) =>
          MediaCleaner.looksLikeImage(Uint8List.fromList(b));
      expect(is_([]), isFalse);
      expect(is_([0xFF, 0xD8]), isFalse, reason: 'too short to be sure');
      expect(is_('PK\x03\x04'.codeUnits), isFalse, reason: 'a zip archive');
      expect(is_('%PDF-1.7'.codeUnits), isFalse);
      expect(is_('plain text, not a picture'.codeUnits), isFalse);
      // RIFF is also WAV and AVI: only RIFF *and* WEBP is an image.
      expect(
        is_([...'RIFF'.codeUnits, 1, 2, 3, 4, ...'WAVE'.codeUnits]),
        isFalse,
      );
      expect(is_('GIF'.codeUnits), isFalse);
    });

    test('judges by what the file is, not what it is called', () async {
      final misnamed = write('holiday.jpg', 'PK\x03\x04 not a photo'.codeUnits);
      final result = await prepareForSending(cleaner(), misnamed.path);

      expect(result!.cleaned.state, CleanState.notAnImage);
      expect(stripped, 0);

      final photo = write('IMG_0001.dat', jpeg + List.filled(100, 7));
      final photoResult = await prepareForSending(cleaner(), photo.path);
      expect(photoResult!.cleaned.state, CleanState.alreadyClean);
      expect(stripped, 1, reason: 'a photograph is still cleaned');
    });

    test('a file that is not an image is not read, and is sent where it is', () async {
      // Large enough to matter if it were loaded; sparse, so it costs nothing.
      final archive = write(
        'big.zip',
        'PK\x03\x04'.codeUnits,
        size: 300 * 1024 * 1024,
      );
      final result = await prepareForSending(cleaner(), archive.path);

      expect(stripped, 0, reason: 'the cleaner never saw it');
      expect(result!.path, archive.path, reason: 'sent from where it is');
      expect(result.size, 300 * 1024 * 1024);
      expect(result.cleaned.state, CleanState.notAnImage);
      expect(result.cleaned.bytes, isEmpty, reason: 'nothing was loaded');
      expect(
        result.cleaned.carriesUnknownData,
        isTrue,
        reason: 'and it still says so',
      );
    });

    test(
      'an image too large to rewrite says so, and is not mislabelled',
      () async {
        final big = write(
          'huge.jpg',
          jpeg,
          size: MediaCleaner.maxCleanableBytes + 1,
        );
        final result = await prepareForSending(cleaner(), big.path);

        expect(stripped, 0);
        expect(result!.cleaned.state, CleanState.tooLarge);
        expect(result.cleaned.carriesUnknownData, isTrue);
        expect(result.cleaned.describe(), contains('Too large'));
        expect(result.cleaned.describe(), isNot(contains('not an image')));
      },
    );

    test('an image just under the limit is still cleaned', () async {
      final fits = write('fits.jpg', jpeg, size: 5 * 1024 * 1024);
      final result = await prepareForSending(cleaner(), fits.path);

      expect(stripped, 1);
      expect(result!.cleaned.state, CleanState.alreadyClean);
    });

    test('with the setting off the file is not read either', () async {
      settings.stripImageMetadata = false;
      final photo = write('p.jpg', jpeg, size: 5 * 1024 * 1024);
      final result = await prepareForSending(cleaner(), photo.path);

      expect(stripped, 0);
      expect(result!.cleaned.state, CleanState.notAttempted);
      expect(result.path, photo.path);
    });

    test('a file that cannot be read is nothing to send', () async {
      final result = await prepareForSending(
        cleaner(),
        '${dir.path}${Platform.pathSeparator}missing.bin',
      );
      expect(result, isNull);
    });

    test('an empty file is a file with nothing to clean', () async {
      final empty = write('empty.txt', const []);
      final result = await prepareForSending(cleaner(), empty.path);

      expect(result!.size, 0);
      expect(result.cleaned.state, CleanState.notAnImage);
    });
  });
}
