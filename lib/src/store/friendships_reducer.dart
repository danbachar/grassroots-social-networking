import 'friendships_state.dart';
import 'friendships_actions.dart';

/// Reducer for friendships state
FriendshipsState friendshipsReducer(FriendshipsState state, FriendshipAction action) {
  if (action is CreateFriendRequestAction) {
    final now = DateTime.now();
    final friendship = FriendshipState(
      peerPubkeyHex: action.peerPubkeyHex,
      nickname: action.nickname,
      status: FriendshipStatus.pending,
      message: action.message,
      createdAt: now,
      updatedAt: now,
    );
    return state.copyWith(
      friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
    );
  }

  if (action is ReceiveFriendRequestAction) {
    final existing = state.friendships[action.peerPubkeyHex];
    final now = DateTime.now();

    // Auto-accept if we already have pending outgoing (mutual friend requests)
    if (existing != null && existing.isPendingOutgoing) {
      final friendship = existing.copyWith(
        status: FriendshipStatus.accepted,
        nickname: action.nickname ?? existing.nickname,
        updatedAt: now,
      );
      return state.copyWith(
        friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
      );
    }

    // Already friends - just update nickname
    if (existing != null && existing.isAccepted) {
      final friendship = existing.copyWith(
        nickname: action.nickname ?? existing.nickname,
        updatedAt: now,
      );
      return state.copyWith(
        friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
      );
    }

    // New incoming request
    final friendship = FriendshipState(
      peerPubkeyHex: action.peerPubkeyHex,
      nickname: action.nickname,
      status: FriendshipStatus.received,
      message: action.message,
      createdAt: now,
      updatedAt: now,
    );
    return state.copyWith(
      friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
    );
  }

  if (action is AcceptFriendRequestAction) {
    final existing = state.friendships[action.peerPubkeyHex];
    if (existing == null || !existing.isPendingIncoming) return state;

    final friendship = existing.copyWith(
      status: FriendshipStatus.accepted,
      updatedAt: DateTime.now(),
    );
    return state.copyWith(
      friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
    );
  }

  if (action is ProcessFriendshipAcceptAction) {
    final existing = state.friendships[action.peerPubkeyHex];
    final now = DateTime.now();

    if (existing == null) {
      // Strange case - they accepted but we never sent request
      // Create a new accepted friendship
      final friendship = FriendshipState(
        peerPubkeyHex: action.peerPubkeyHex,
        nickname: action.nickname,
        status: FriendshipStatus.accepted,
        createdAt: now,
        updatedAt: now,
      );
      return state.copyWith(
        friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
      );
    }

    final friendship = existing.copyWith(
      status: FriendshipStatus.accepted,
      nickname: action.nickname ?? existing.nickname,
      updatedAt: now,
    );
    return state.copyWith(
      friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
    );
  }

  if (action is DeclineFriendRequestAction) {
    final existing = state.friendships[action.peerPubkeyHex];
    if (existing == null || !existing.isPendingIncoming) return state;

    final friendship = existing.copyWith(
      status: FriendshipStatus.declined,
      updatedAt: DateTime.now(),
    );
    return state.copyWith(
      friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
    );
  }

  if (action is RemoveFriendshipAction) {
    final newMap = Map<String, FriendshipState>.from(state.friendships);
    newMap.remove(action.peerPubkeyHex);
    return state.copyWith(friendships: newMap);
  }

  if (action is HandleUnfriendedByAction) {
    final newMap = Map<String, FriendshipState>.from(state.friendships);
    newMap.remove(action.peerPubkeyHex);
    return state.copyWith(friendships: newMap);
  }

  if (action is HydrateFriendshipsAction) {
    return state.copyWith(friendships: action.friendships);
  }

  if (action is UpdateFriendshipUdpAddressAction) {
    final existing = state.friendships[action.peerPubkeyHex];
    if (existing == null) return state;

    final friendship = existing.copyWith(
      udpAddress: action.udpAddress ?? existing.udpAddress,
      updatedAt: DateTime.now(),
    );
    return state.copyWith(
      friendships: Map.from(state.friendships)..[action.peerPubkeyHex] = friendship,
    );
  }

  return state;
}
