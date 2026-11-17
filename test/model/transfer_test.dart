// How a transfer describes itself.
//
// The moving parts of DCC are in Rust and tested there, over a real loopback
// socket. What is left on this side is presentation, and two bits of it are
// worth pinning down: a progress fraction that has to survive a sender lying
// about the size, and the wording of an outcome, which is the only record of
// the transfer that outlives it.

import 'package:flutter_test/flutter_test.dart';

import 'package:ddirc/src/model/transfer.dart';

FileTransfer running({BigInt? total, int done = 0}) {
  final transfer = FileTransfer.running(
    id: BigInt.one,
    filename: 'holiday.jpg',
    incoming: true,
    total: total,
  );
  transfer.transferred = BigInt.from(done);
  return transfer;
}

void main() {
  group('progress', () {
    test('is null while the size is unknown, so the bar stays honest', () {
      // An old client may omit the size, and it is allowed to. An
      // indeterminate bar says "moving, do not know how far"; a bar sitting at
      // zero would say something false.
      expect(running(total: null, done: 4096).fraction, isNull);
    });

    test('runs from nothing to everything', () {
      expect(running(total: BigInt.from(100), done: 0).fraction, 0.0);
      expect(running(total: BigInt.from(100), done: 25).fraction, 0.25);
      expect(running(total: BigInt.from(100), done: 100).fraction, 1.0);
    });

    // The size in an offer is the sender's claim, not a fact. A sender who
    // understates it would otherwise drive the bar past its own end.
    test('cannot be driven past the end by a sender who understated it', () {
      expect(running(total: BigInt.from(100), done: 900).fraction, 1.0);
    });

    test('a nonsense size is treated as no size at all', () {
      expect(running(total: BigInt.zero, done: 10).fraction, isNull);
      expect(running(total: BigInt.from(-5), done: 10).fraction, isNull);
    });
  });

  group('sizes', () {
    test('are shown in the largest unit that leaves a readable number', () {
      expect(FileTransfer.describeSize(BigInt.from(512)), '512 B');
      expect(FileTransfer.describeSize(BigInt.from(2048)), '2 KB');
      expect(FileTransfer.describeSize(BigInt.from(5 * 1024 * 1024)), '5.0 MB');
      expect(
        FileTransfer.describeSize(BigInt.from(3 * 1024 * 1024 * 1024)),
        '3.0 GB',
      );
    });

    test('an absent size says so rather than showing a zero', () {
      expect(FileTransfer.describeSize(null), 'unknown size');
    });
  });

  group('the line left in the scrollback', () {
    // A download the user cannot find is a download that did not happen.
    test('a received file says where it went', () {
      expect(
        FileTransfer.describeOutcome(
          filename: 'holiday.jpg',
          path: r'C:\Users\me\AppData\Roaming\ddIRC\received\holiday.jpg',
          error: null,
        ),
        contains(r'received\holiday.jpg'),
      );
    });

    test('a sent file just says it went', () {
      expect(
        FileTransfer.describeOutcome(
          filename: 'holiday.jpg',
          path: null,
          error: null,
        ),
        'sent "holiday.jpg"',
      );
    });

    test('a failure carries the reason, not just the fact', () {
      expect(
        FileTransfer.describeOutcome(
          filename: 'holiday.jpg',
          path: null,
          error: 'nobody connected within 120 seconds',
        ),
        'transfer of "holiday.jpg" failed: nobody connected within 120 seconds',
      );
    });

    // An error wins over a path, because a transfer that failed after writing
    // something must never read as one that succeeded.
    test('a failure is a failure even if a path came back with it', () {
      final line = FileTransfer.describeOutcome(
        filename: 'half.bin',
        path: '/somewhere/half.bin',
        error: 'the sender stopped after 4 of 100 bytes',
      );
      expect(line, startsWith('transfer of "half.bin" failed'));
      expect(line, isNot(contains('saved')));
    });
  });

  group('an offer', () {
    test('carries no progress of its own until it is accepted', () {
      final offered = FileTransfer.offered(
        id: BigInt.one,
        filename: 'cat.jpg',
        from: 'mallory',
        total: BigInt.from(2048),
        isReverse: false,
      );
      expect(offered.stage, TransferStage.offered);
      expect(offered.transferred, BigInt.zero);
      expect(offered.incoming, isTrue, reason: 'an offer is always incoming');
    });

    // A reverse offer asks us to listen, which means telling the sender where
    // we are. The core refuses that behind a proxy; the flag is how the UI
    // knows which kind it is looking at.
    test('knows whether accepting would mean listening', () {
      final reverse = FileTransfer.offered(
        id: BigInt.one,
        filename: 'cat.jpg',
        from: 'mallory',
        total: null,
        isReverse: true,
      );
      expect(reverse.isReverse, isTrue);
    });
  });
}
