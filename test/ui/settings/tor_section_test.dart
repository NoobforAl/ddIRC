// What the Tor section's Status row says.
//
// The row used to print the core's own summary once Tor was ready: "Ready —
// 100%: connecting successfully; directory is usable, fresh until 2026-11-17
// 08:00:00 UTC, and valid until 2026-11-17 10:00:00 UTC". That is the
// directory's bookkeeping, not an answer to "is it working", and on a phone it
// wrapped to four lines with timestamps in a zone nobody chose. These hold it
// to the answer.
//
// Asked as a function because the page the row sits on cannot be built in a
// widget test: the proxy section beside it asks the core for the Tor port, and
// there is no core here.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/tor.dart';
import 'package:ddirc/src/ui/settings/tor_section.dart';

/// What the core says once the directory is usable — the sentence that was
/// being shown, kept verbatim so the test fails for the right reason if the
/// row ever starts printing it again.
const _readySummary =
    '100%: connecting successfully; directory is usable, '
    'fresh until 2026-11-17 08:00:00 UTC, and valid until '
    '2026-11-17 10:00:00 UTC';

void main() {
  const ready = TorProgress(ready: true, progress: 1, summary: _readySummary);
  const starting = TorProgress(
    ready: false,
    progress: 0.15,
    summary: 'handshaking with a relay',
  );

  String line({
    bool offline = false,
    bool running = true,
    TorProgress progress = ready,
  }) => torStatusLine(offline: offline, running: running, progress: progress);

  test('a Tor that is ready says "Ready" and nothing about the directory', () {
    expect(line(), 'Ready');
    expect(line(), isNot(contains('UTC')));
    expect(line(), isNot(contains('directory')));
  });

  test('while it starts, it says how far and which step', () {
    // The summary is the only thing that says what a slow start is waiting
    // on, so it stays here — beside the percentage, where it is useful.
    expect(line(progress: starting), '15% — handshaking with a relay');
  });

  test('losing the network outranks everything Tor itself reports', () {
    // Tor goes on saying "Ready" with no network, which is why the app checks.
    expect(line(offline: true), 'Waiting for the network');
    expect(line(offline: true, progress: starting), 'Waiting for the network');
  });

  test('a Tor that is not running says so', () {
    expect(line(running: false, progress: TorProgress.off), 'Not running');
  });
}
