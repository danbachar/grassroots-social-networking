import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/store/peers_actions.dart';
import 'package:grassroots_networking/src/store/sessions_reducer.dart';
import 'package:grassroots_networking/src/store/sessions_state.dart';

/// A non-session action, to verify the slice ignores what is not its business.
class _UnknownAction extends PeerAction {}

/// The sessions slice is a projection of session-layer facts, and the purge
/// actions are the destructive half of it. These pin the half that is easy to
/// get wrong: a per-peer purge must take exactly one entry.
///
/// Getting that wrong is not a cosmetic bug. `SessionsState.has` is what the
/// composer is gated on, and a packet may not exist before a session with its
/// target does — so a reducer that dropped a neighbour it was not asked about
/// would present that peer as unmessageable while the session manager would
/// still happily seal to them, and one that dropped nothing would leave a
/// purged peer looking sendable.
void main() {
  Uint8List pubkey(int fill) =>
      Uint8List.fromList(List.filled(32, fill));

  String hexOf(Uint8List key) =>
      key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  final alice = pubkey(0xaa);
  final bob = pubkey(0xbb);
  final carol = pubkey(0xcc);

  group('sessionsReducer', () {
    test('unknown action returns the same state unchanged', () {
      const state = SessionsState(establishedAtMs: {'aa': 1});
      expect(sessionsReducer(state, _UnknownAction()), same(state));
    });

    group('PeerNoiseSessionEstablishedAction', () {
      test('adds the peer, keyed by lowercase pubkey hex', () {
        const state = SessionsState();
        final result =
            sessionsReducer(state, PeerNoiseSessionEstablishedAction(alice));

        expect(result.has(hexOf(alice)), isTrue);
        expect(result.count, 1);
      });

      test('keeps sessions already held', () {
        final first =
            sessionsReducer(const SessionsState(),
                PeerNoiseSessionEstablishedAction(alice));
        final second =
            sessionsReducer(first, PeerNoiseSessionEstablishedAction(bob));

        expect(second.count, 2);
        expect(second.has(hexOf(alice)), isTrue);
        expect(second.has(hexOf(bob)), isTrue);
      });
    });

    group('PeerNoiseSessionResetAction', () {
      test('removes the named session and leaves the others intact', () {
        final state = SessionsState(establishedAtMs: {
          hexOf(alice): 100,
          hexOf(bob): 200,
          hexOf(carol): 300,
        });

        final result = sessionsReducer(state, PeerNoiseSessionResetAction(bob));

        expect(result.has(hexOf(bob)), isFalse);
        expect(result.has(hexOf(alice)), isTrue);
        expect(result.has(hexOf(carol)), isTrue);
        expect(result.count, 2);
        // The surviving entries keep their own establishment times — the
        // purge is a removal, never a re-stamp of the table.
        expect(result.establishedAtMs[hexOf(alice)], 100);
        expect(result.establishedAtMs[hexOf(carol)], 300);
      });

      test('removing an absent key is a no-op', () {
        final state = SessionsState(establishedAtMs: {hexOf(alice): 100});

        final result =
            sessionsReducer(state, PeerNoiseSessionResetAction(carol));

        expect(result.count, 1);
        expect(result.has(hexOf(alice)), isTrue);
        // Same instance, not merely an equal one: nothing happened, so the
        // store has no change to broadcast.
        expect(result, same(state));
      });

      test('does not mutate the previous state in place', () {
        final state = SessionsState(establishedAtMs: {
          hexOf(alice): 100,
          hexOf(bob): 200,
        });

        sessionsReducer(state, PeerNoiseSessionResetAction(alice));

        expect(state.count, 2, reason: 'the old state must stay valid');
        expect(state.has(hexOf(alice)), isTrue);
      });

      test('purging the last session empties the slice', () {
        final state = SessionsState(establishedAtMs: {hexOf(alice): 100});

        final result =
            sessionsReducer(state, PeerNoiseSessionResetAction(alice));

        expect(result.count, 0);
        expect(result.peerHexes, isEmpty);
      });

      test('a peer can be re-established after being purged', () {
        final state = SessionsState(establishedAtMs: {hexOf(alice): 100});
        final purged =
            sessionsReducer(state, PeerNoiseSessionResetAction(alice));
        final again = sessionsReducer(
            purged, PeerNoiseSessionEstablishedAction(alice));

        expect(again.has(hexOf(alice)), isTrue);
        expect(again.count, 1);
      });
    });

    group('AllNoiseSessionsResetAction', () {
      test('clears every session', () {
        final state = SessionsState(establishedAtMs: {
          hexOf(alice): 100,
          hexOf(bob): 200,
          hexOf(carol): 300,
        });

        final result =
            sessionsReducer(state, AllNoiseSessionsResetAction());

        expect(result.count, 0);
        expect(result.establishedAtMs, isEmpty);
      });

      test('clearing an already empty slice stays empty', () {
        final result = sessionsReducer(
            const SessionsState(), AllNoiseSessionsResetAction());

        expect(result.count, 0);
      });
    });
  });
}
