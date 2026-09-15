import 'peers_actions.dart';
import 'sessions_state.dart';

/// Sessions are facts with exactly three sources: an establishment reported
/// by the session manager, the testbed's blanket purge, and the operator's
/// per-peer purge from the settings session table. All three are reported by
/// the layer that owns the session — the reducer never decides that a session
/// ended, it is told. No peer-record action touches this slice — that
/// independence is the point.
///
/// The two purges differ only in scope; neither is an inference. Each is
/// dispatched AFTER `NoiseSessionManager` has actually forgotten the entry,
/// so the projection trails the fact and can never claim a peer is unsealable
/// while the manager would still seal to it.
SessionsState sessionsReducer(SessionsState state, dynamic action) {
  if (action is PeerNoiseSessionEstablishedAction) {
    final hex = action.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    return state.copyWith(establishedAtMs: {
      ...state.establishedAtMs,
      hex: DateTime.now().millisecondsSinceEpoch,
    });
  }
  if (action is PeerNoiseSessionResetAction) {
    final hex = action.publicKey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    // Absent key: return the SAME instance rather than an equal copy. The
    // settings screen rebuilds on every store change, and handing back a new
    // map for a purge that removed nothing would churn identity comparisons
    // for no fact.
    if (!state.establishedAtMs.containsKey(hex)) return state;
    final next = Map<String, int>.from(state.establishedAtMs)..remove(hex);
    return state.copyWith(establishedAtMs: next);
  }
  if (action is AllNoiseSessionsResetAction) {
    return const SessionsState();
  }
  return state;
}
