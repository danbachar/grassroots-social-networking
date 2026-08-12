import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show shouldParkUnsealedSend;

/// Regression tests for the send gate.
///
/// The gate used to be "is there a peer record", which quietly defeated
/// store-carry-forward: the 20 s stale sweep delists a non-friend peer while
/// its Noise session survives, so a recipient that had simply gone quiet lost
/// its record and every message to it skipped sealing — no packetId, never in
/// the DTN buffer, so no relay could carry it and no sync-on-connect exchange
/// could offer it. Reproduced on hardware 2026-08-10: 34 sends to a quiet
/// peer, all parked in the capped plaintext hold, none buffered.
void main() {
  group('shouldParkUnsealedSend', () {
    test('a session alone is enough — this is the case that regressed', () {
      // Quiet recipient: delisted by the stale sweep, session intact. The
      // message must be SEALED and buffered so the mesh can carry it.
      expect(
        shouldParkUnsealedSend(hasPeerRecord: false, hasSession: true),
        isFalse,
      );
    });

    test('a record alone is enough — there is something to handshake against',
        () {
      expect(
        shouldParkUnsealedSend(hasPeerRecord: true, hasSession: false),
        isFalse,
      );
    });

    test('both present is obviously sendable', () {
      expect(
        shouldParkUnsealedSend(hasPeerRecord: true, hasSession: true),
        isFalse,
      );
    });

    test('neither: nothing to seal to and nobody to handshake with', () {
      expect(
        shouldParkUnsealedSend(hasPeerRecord: false, hasSession: false),
        isTrue,
      );
    });
  });
}
