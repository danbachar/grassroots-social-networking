import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:grassroots_networking/src/grassroots_network.dart'
    show processLinkSettledTransitions;
import 'package:grassroots_networking/src/models/peer.dart';
import 'package:grassroots_networking/src/store/peers_state.dart';

/// The edge detector behind `GrassrootsNetwork.peerLinkSettled`.
///
/// The contract: fire only on a false→true edge of the settled predicate, so
/// a waiter learns of convergence the instant it happens instead of polling
/// for it — and so a store change that leaves settledness alone is silent.
void main() {
  Uint8List pubkey(int seed) =>
      Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));

  PeersState stateWith(List<PeerState> peers) => PeersState.initial
      .copyWith(peers: {for (final p in peers) p.pubkeyHex: p});

  PeerState peer(int seed) => PeerState(
        publicKey: pubkey(seed),
        nickname: 'P$seed',
        connectionState: PeerConnectionState.connected,
        transport: PeerTransport.bleDirect,
      );

  ({List<Uint8List> fired, Set<String> settled}) run(
    PeersState state,
    Set<Uint8List> settledNow, {
    Set<String>? carry,
  }) {
    final fired = <Uint8List>[];
    final seen = carry ?? <String>{};
    processLinkSettledTransitions(
      peersState: state,
      isSettled: (pk) => settledNow.any((s) => s.toString() == pk.toString()),
      settled: seen,
      onSettled: fired.add,
    );
    return (fired: fired, settled: seen);
  }

  test('fires once on the edge, and stays quiet while settled', () {
    final state = stateWith([peer(1), peer(2)]);
    final settledNow = {pubkey(1)};

    final first = run(state, settledNow);
    expect(first.fired.length, 1, reason: 'peer 1 just settled');

    // A later store change that alters nothing about settledness is silent.
    final second = run(state, settledNow, carry: first.settled);
    expect(second.fired, isEmpty,
        reason: 'still settled is a level, not an edge');
  });

  test('a pair that unsettles can report again when it settles anew', () {
    final state = stateWith([peer(1)]);
    final carry = run(state, {pubkey(1)}).settled;

    // The per-step reset drops the pair...
    final dropped = run(state, <Uint8List>{}, carry: carry);
    expect(dropped.fired, isEmpty);
    expect(dropped.settled, isEmpty, reason: 'it left the settled set');

    // ...and the next establishment is a real edge, not a duplicate.
    final again = run(state, {pubkey(1)}, carry: dropped.settled);
    expect(again.fired.length, 1);
  });

  test('a peer dropped from the store does not suppress its next edge', () {
    final carry = run(stateWith([peer(1)]), {pubkey(1)}).settled;
    expect(carry, isNotEmpty);

    // Gone from the store entirely — a stale entry here would swallow the
    // edge when the peer comes back.
    final gone = run(stateWith([]), {pubkey(1)}, carry: carry);
    expect(gone.settled, isEmpty);

    final back = run(stateWith([peer(1)]), {pubkey(1)}, carry: gone.settled);
    expect(back.fired.length, 1);
  });
}
