// Tests for what the app calls itself.
//
// The version is written down twice — in `pubspec.yaml`, which is what the
// installer and the store metadata read, and in `lib/src/version.dart`, which
// is what the app itself shows. Neither can read the other at runtime, so the
// only thing standing between them and quiet disagreement is this file.
//

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/version.dart';

/// The `version:` line from the manifest, without its build number.
String _manifestVersion() {
  final line = File('pubspec.yaml')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('version:'));
  return line.substring('version:'.length).trim().split('+').first;
}

void main() {
  test('the version the app shows is the version it was built as', () {
    // Fails on a release where someone bumped the manifest and forgot the
    // constant — which would ship a build quietly claiming to be the last one.
    expect(appVersion, _manifestVersion());
  });

  test('the label carries the version', () {
    expect(appVersionLabel, contains(appVersion));
  });
}
