import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show canAttemptQueuedSend;

/// Tests for [canAttemptQueuedSend], the predicate that decides whether a
/// queued outbound message may be drained (re-attempted) for a recipient.
///
/// Regression context: a message queued while offline used to sit until the
/// recipient reconnected *directly*, because the drain was gated on a direct
/// link. But a fresh `send()` floods to any recipient we hold a Noise session
/// with, reaching them over the mesh via relays. So the drain must also fire
/// when only a relay (non-direct) neighbor is present — i.e. when BLE is usable
/// and a Noise session exists, regardless of a direct path.
void main() {
  group('canAttemptQueuedSend', () {
    test('drains over the mesh with only a relay present (the bug fix)', () {
      // No direct path to the recipient, but BLE is up and we hold a Noise
      // session — a relay can carry the flood.
      expect(
        canAttemptQueuedSend(
          hasDirectSendPath: false,
          bleUsable: true,
          hasNoiseSession: true,
        ),
        isTrue,
      );
    });

    test('drains when a direct path exists (regardless of BLE/session)', () {
      expect(
        canAttemptQueuedSend(
          hasDirectSendPath: true,
          bleUsable: false,
          hasNoiseSession: false,
        ),
        isTrue,
      );
    });

    test('does NOT drain when BLE is down and no direct path', () {
      // e.g. adapter powered off — this is the state the message was queued in.
      expect(
        canAttemptQueuedSend(
          hasDirectSendPath: false,
          bleUsable: false,
          hasNoiseSession: true,
        ),
        isFalse,
      );
    });

    test('does NOT drain over the mesh without a Noise session', () {
      // BLE is up but we have never handshaked with this recipient, so a flood
      // cannot be sealed to them — nothing to attempt yet.
      expect(
        canAttemptQueuedSend(
          hasDirectSendPath: false,
          bleUsable: true,
          hasNoiseSession: false,
        ),
        isFalse,
      );
    });

    test('does NOT drain with no path at all', () {
      expect(
        canAttemptQueuedSend(
          hasDirectSendPath: false,
          bleUsable: false,
          hasNoiseSession: false,
        ),
        isFalse,
      );
    });
  });
}
