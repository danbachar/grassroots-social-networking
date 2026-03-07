import 'friendships_state.dart';

/// Base class for friendship-related actions
abstract class FriendshipAction {}

/// Create a new outgoing friend request
class CreateFriendRequestAction extends FriendshipAction {
  final String peerPubkeyHex;
  final String? nickname;
  final String? message;

  CreateFriendRequestAction({
    required this.peerPubkeyHex,
    this.nickname,
    this.message,
  });
}

/// Record a received friend request
class ReceiveFriendRequestAction extends FriendshipAction {
  final String peerPubkeyHex;
  final String? nickname;
  final String? message;

  ReceiveFriendRequestAction({
    required this.peerPubkeyHex,
    this.nickname,
    this.message,
  });
}

/// Accept an incoming friend request
class AcceptFriendRequestAction extends FriendshipAction {
  final String peerPubkeyHex;

  AcceptFriendRequestAction(this.peerPubkeyHex);
}

/// Process a friendship accept message from the other party
class ProcessFriendshipAcceptAction extends FriendshipAction {
  final String peerPubkeyHex;
  final String? nickname;

  ProcessFriendshipAcceptAction({
    required this.peerPubkeyHex,
    this.nickname,
  });
}

/// Decline a friend request
class DeclineFriendRequestAction extends FriendshipAction {
  final String peerPubkeyHex;

  DeclineFriendRequestAction(this.peerPubkeyHex);
}

/// Remove a friendship (unfriend)
class RemoveFriendshipAction extends FriendshipAction {
  final String peerPubkeyHex;

  RemoveFriendshipAction(this.peerPubkeyHex);
}

/// Handle being unfriended by someone
class HandleUnfriendedByAction extends FriendshipAction {
  final String peerPubkeyHex;

  HandleUnfriendedByAction(this.peerPubkeyHex);
}

/// Hydrate friendships from persistence
class HydrateFriendshipsAction extends FriendshipAction {
  final Map<String, FriendshipState> friendships;

  HydrateFriendshipsAction(this.friendships);
}

/// Update friendship's libp2p info (e.g., after reconnection)
class UpdateFriendshipLibp2pInfoAction extends FriendshipAction {
  final String peerPubkeyHex;
  final String? libp2pAddress;
  final String? libp2pHostId;
  final List<String>? libp2pHostAddrs;

  UpdateFriendshipLibp2pInfoAction({
    required this.peerPubkeyHex,
    this.libp2pAddress,
    this.libp2pHostId,
    this.libp2pHostAddrs,
  });
}
