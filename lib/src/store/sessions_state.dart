import 'package:flutter/foundation.dart';

/// The Noise sessions this device holds, projected as facts: WITH WHOM and
/// SINCE WHEN. Nothing more — the cryptographic state (cipher states,
/// nonces, keys) lives only in the session manager, which is the crypto
/// authority; putting key material in an observable state tree would leak
/// it to logging and persistence, and the nonces advance on every sealed
/// packet, which no projection can chase.
///
/// Its own slice, NOT a flag on the peer record, because the two have
/// different lifetimes: a session is keyed by identity and lives until an
/// explicit reset, while a peer record is presence-scoped and the stale
/// sweep deletes it after silence. A flag riding the record died with it —
/// and re-establishment never fires for a pair that already holds a
/// session, so the projection stayed wrong forever and everything that
/// targets by session saw a sendable peer as a stranger.
@immutable
class SessionsState {
  /// Peer pubkey hex (lowercase) -> when the session (last) established, ms.
  final Map<String, int> establishedAtMs;

  const SessionsState({this.establishedAtMs = const {}});

  bool has(String pubkeyHex) =>
      establishedAtMs.containsKey(pubkeyHex.toLowerCase());

  /// Identities a message can be sealed to right now.
  Iterable<String> get peerHexes => establishedAtMs.keys;

  int get count => establishedAtMs.length;

  SessionsState copyWith({Map<String, int>? establishedAtMs}) =>
      SessionsState(establishedAtMs: establishedAtMs ?? this.establishedAtMs);

  @override
  bool operator ==(Object other) =>
      other is SessionsState &&
      mapEquals(other.establishedAtMs, establishedAtMs);

  @override
  int get hashCode => Object.hashAll(
      establishedAtMs.entries.map((e) => Object.hash(e.key, e.value)));
}
