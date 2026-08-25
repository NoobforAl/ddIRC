// Tests for the error-message tidy-up.
//
// The bug these pin down was live: `AnyhowException.toString()` is
// `AnyhowException(<message>)` — parentheses, not a colon — so the old
// `^[A-Za-z]*Exception:\s*` strip never matched anything crossing the FFI
// boundary, and the wrapper was shown to the user along with the message the
// core had gone to the trouble of writing.

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/errors.dart';

void main() {
  test('unwraps an error that came from the core', () {
    const message =
        'port 6667 is a plaintext IRC port; ddIRC requires TLS. Use 6697.';
    final described = describeError(AnyhowException(message));

    expect(described, message);
    expect(described, isNot(contains('AnyhowException')));
  });

  test('says plainly when the fault is ours', () {
    // A panic is a bug, not a mistake the user made. Telling them so is the
    // difference between an hour spent re-checking their settings and the
    // report that gets it fixed.
    final described = describeError(PanicException('index out of bounds'));

    expect(described, contains('bug'));
    expect(described, contains('index out of bounds'));
  });

  test('strips the prefix from an ordinary Dart exception', () {
    expect(describeError(Exception('no route to host')), 'no route to host');
    expect(
      describeError(const FormatException('not a number')),
      'not a number',
    );
  });

  test('never returns an empty string', () {
    // Whatever arrives, the UI has something to render — an error bar showing
    // nothing at all reads as a rendering bug rather than as a failure.
    for (final error in <Object?>[null, Exception(''), '', '   ']) {
      expect(describeError(error), isNotEmpty);
    }
  });

  test('leaves a message that needs no tidying untouched', () {
    const message = 'Could not find \'irc.exmaple.org\'. Check for a typo.';
    expect(describeError(AnyhowException(message)), message);
  });
}
