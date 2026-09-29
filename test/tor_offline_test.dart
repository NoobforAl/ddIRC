// Tor cannot tell that the device has lost its network — its status goes on
// saying "Ready" — so the app checks, and says so instead.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ddirc/src/model/tor.dart';

void main() {
  late bool online;

  setUp(() {
    online = true;
    TorSettings.hasNetwork = () async => online;
    SharedPreferences.setMockInitialValues({});
  });

  test('losing the network is said, and coming back clears it', () async {
    final tor = await TorSettings.load();
    tor.runningForTesting(9050);
    var changes = 0;
    tor.addListener(() => changes++);

    await tor.checkNetwork();
    expect(tor.offline, isFalse);
    expect(changes, 0, reason: 'nothing changed, nothing said');

    online = false;
    await tor.checkNetwork();
    expect(tor.offline, isTrue);
    expect(tor.progress.ready, isFalse);
    expect(tor.progress.summary, contains('waiting for the network'));
    expect(tor.progress.blocked, isNotNull);
    expect(changes, 1);

    online = true;
    await tor.checkNetwork();
    expect(tor.offline, isFalse);
    expect(tor.progress.summary, isNot(contains('waiting')));
    expect(changes, 2);
  });

  test('a Tor that is not running is never "offline"', () async {
    final tor = await TorSettings.load();
    online = false;
    await tor.checkNetwork();
    expect(tor.offline, isFalse);
    expect(tor.progress.summary, 'Off');
  });
}
