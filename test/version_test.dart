// Tests for what the app calls itself.
//
// The version is written down twice — in `pubspec.yaml`, which is what the
// installer and the store metadata read, and in `lib/src/version.dart`, which
// is what the app itself shows. Neither can read the other at runtime, so the
// only thing standing between them and quiet disagreement is this file.
//
// The beta mark is here for a different reason. It is a claim the README makes
// and the app repeats, and it should stop being made deliberately rather than
// by someone editing a string and not noticing what it was for.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/version.dart';

/// The `version:` line from the manifest, without its build number.
String _manifestVersion() {
  final line = File(
    'pubspec.yaml',
  ).readAsLinesSync().firstWhere((l) => l.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

void main() {
  test('the version the app shows is the version it was built as', () {
    // Fails on a release where someone bumped the manifest and forgot the
    // constant — which would ship a build quietly claiming to be the last one.
    expect(appVersion, _manifestVersion());
  });

  test('the label carries the version and says beta', () {
    expect(appVersionLabel, contains(appVersion));
    // Lower case, because it is read as prose in a sentence rather than as a
    // badge. The badge is a separate widget with its own wording.
    expect(appVersionLabel, contains('beta'));
  });
}
