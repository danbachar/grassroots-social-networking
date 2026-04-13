import 'dart:io';
import 'dart:typed_data';

import 'address_table.dart';
import 'peer_table.dart';
import 'protocol.dart';
import 'signaling_codec.dart';

/// Handles all signaling logic for the bootstrap anchor.
///
/// The anchor is a personal well-connected friend — it only serves the
/// owner and their explicit friend list. Signaling from strangers is dropped.
///
/// Responsibilities:
/// - Maintains an address table from friend ANNOUNCE packets.
/// - Responds to ADDR_QUERY from friends.
/// - Coordinates hole-punches between friends on PUNCH_REQUEST.
/// - Reflects observed addresses back via ADDR_REFLECT.
/// - Forwards PUNCH_READY between counterparts.
class SignalingHandler {
  final Protocol protocol;
  final PeerTable peerTable;
  final AddressTable addressTable;
  final SignalingCodec codec;

  /// When coordinating a punch, remember the counterpart for PUNCH_READY forwarding.
  final Map<String, Uint8List> _pendingPunchCounterparts = {};

  /// Callback to send a signed signaling packet to a peer.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
      sendSignaling;

  SignalingHandler({
    required this.protocol,
    required this.peerTable,
    required this.addressTable,
    this.codec = const SignalingCodec(),
  });

  /// Process an ANNOUNCE received over UDP from a peer.
  ///
  /// Only registers addresses for friends. Strangers are tracked in the
  /// peer table (for diagnostics) but get no address table entry.
  void processAnnounce(
    AnnounceData data, {
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = data.pubkeyHex;

    // Update peer table (friends get real entries, strangers get logged)
    peerTable.upsert(
      publicKey: data.publicKey,
      nickname: data.nickname,
      pubkeyHex: senderHex,
      udpAddress: data.udpAddress,
    );

    // Only register addresses for friends
    if (!peerTable.isFriend(senderHex)) {
      _log('ANNOUNCE from stranger ${data.nickname} '
          '(${senderHex.substring(0, 8)}...) — ignored');
      return;
    }

    // Determine effective address (prefer observed over claimed)
    String? effectiveIp;
    int? effectivePort;

    if (observedIp != null && observedPort != null) {
      effectiveIp = observedIp;
      effectivePort = observedPort;
    } else if (data.udpAddress != null) {
      final parsed = _parseAddress(data.udpAddress!);
      if (parsed != null) {
        effectiveIp = parsed.ip;
        effectivePort = parsed.port;
      }
    }

    if (effectiveIp != null && effectivePort != null) {
      if (InternetAddress.tryParse(effectiveIp)?.type ==
          InternetAddressType.IPv6) {
        addressTable.register(senderHex, effectiveIp, effectivePort);
        _log('Address registered: ${data.nickname} '
            '(${senderHex.substring(0, 8)}...) → $effectiveIp:$effectivePort');
      } else {
        _log('Ignoring non-IPv6 address for ${data.nickname}: '
            '$effectiveIp:$effectivePort');
      }
    }

    // Reflect observed address back to the friend
    if (observedIp != null && observedPort != null) {
      final reflect = AddrReflectMessage(ip: observedIp, port: observedPort);
      sendSignaling?.call(data.publicKey, codec.encode(reflect));
    }
  }

  /// Process an incoming signaling packet.
  void processSignaling(Uint8List senderPubkey, Uint8List payload) {
    final senderHex = _pubkeyToHex(senderPubkey);

    // Only process signaling from the owner or friends — drop strangers.
    // Exception: the owner is always allowed (they may be connecting for the
    // first time and need to send FRIENDS_SYNC before the table is populated).
    final isOwner = senderHex == peerTable.ownerPubkeyHex;
    if (!isOwner && !peerTable.isFriend(senderHex)) {
      _log('Dropping signaling from non-friend ${senderHex.substring(0, 8)}...');
      return;
    }

    SignalingMessage msg;
    try {
      msg = codec.decode(payload);
    } catch (e) {
      _log('Failed to decode signaling from ${senderHex.substring(0, 8)}...: $e');
      return;
    }

    final senderName =
        peerTable.lookupFriend(senderHex)?.nickname ?? senderHex.substring(0, 8);
    _log('Signaling from $senderName: ${msg.runtimeType}');

    switch (msg) {
      case AddrQueryMessage():
        _handleAddrQuery(senderPubkey, msg);
      case AddrResponseMessage():
        _log('Ignoring AddrResponse (anchor does not query)');
      case PunchRequestMessage():
        _handlePunchRequest(senderPubkey, senderHex, msg);
      case PunchInitiateMessage():
        _log('Ignoring PunchInitiate (anchor is well-connected)');
      case PunchReadyMessage():
        _handlePunchReady(senderPubkey, msg);
      case AddrReflectMessage():
        _log('Ignoring AddrReflect (anchor knows its own address)');
      case FriendsSyncMessage():
        _handleFriendsSync(senderPubkey, senderHex, msg);
    }
  }

  void _handleAddrQuery(Uint8List senderPubkey, AddrQueryMessage msg) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);

    // Only answer queries for targets that are also our friends.
    // The anchor only keeps addresses of friends, so this is implicit,
    // but we check explicitly for clarity.
    if (!peerTable.isFriend(targetHex)) {
      _log('Addr query for non-friend ${targetHex.substring(0, 8)}... — not found');
      final response = AddrResponseMessage(targetPubkey: msg.targetPubkey);
      sendSignaling?.call(senderPubkey, codec.encode(response));
      return;
    }

    final entry = addressTable.lookup(targetHex);
    final response = AddrResponseMessage(
      targetPubkey: msg.targetPubkey,
      ip: entry?.ip,
      port: entry?.port,
    );
    sendSignaling?.call(senderPubkey, codec.encode(response));

    _log('Addr query for ${targetHex.substring(0, 8)}...: '
        '${entry != null ? "${entry.ip}:${entry.port}" : "not found"}');
  }

  void _handlePunchRequest(
    Uint8List requesterPubkey,
    String requesterHex,
    PunchRequestMessage msg,
  ) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);

    // Both requester and target must be friends. We only coordinate
    // hole-punches between peers we trust.
    if (!peerTable.isFriend(targetHex)) {
      _log('Punch request for non-friend target ${targetHex.substring(0, 8)}... — ignoring');
      return;
    }

    final requesterAddr = addressTable.lookup(requesterHex);
    final targetAddr = addressTable.lookup(targetHex);

    if (requesterAddr == null) {
      _log('Punch request from ${requesterHex.substring(0, 8)}... '
          'but they have no registered address');
      return;
    }
    if (targetAddr == null) {
      _log('Punch request for ${targetHex.substring(0, 8)}... '
          'but they have no registered address');
      return;
    }

    final requesterName =
        peerTable.lookupFriend(requesterHex)?.nickname ?? requesterHex.substring(0, 8);
    final targetName =
        peerTable.lookupFriend(targetHex)?.nickname ?? targetHex.substring(0, 8);

    _log('Coordinating hole-punch: '
        '$requesterName(${requesterAddr.ip}:${requesterAddr.port}) <-> '
        '$targetName(${targetAddr.ip}:${targetAddr.port})');

    // Remember counterparts for PUNCH_READY forwarding
    _pendingPunchCounterparts[requesterHex] = msg.targetPubkey;
    _pendingPunchCounterparts[targetHex] = requesterPubkey;

    // Tell requester to punch toward target
    final initiateToRequester = PunchInitiateMessage(
      peerPubkey: msg.targetPubkey,
      ip: targetAddr.ip,
      port: targetAddr.port,
    );
    sendSignaling?.call(requesterPubkey, codec.encode(initiateToRequester));

    // Tell target to punch toward requester
    final initiateToTarget = PunchInitiateMessage(
      peerPubkey: requesterPubkey,
      ip: requesterAddr.ip,
      port: requesterAddr.port,
    );
    sendSignaling?.call(msg.targetPubkey, codec.encode(initiateToTarget));
  }

  void _handlePunchReady(Uint8List senderPubkey, PunchReadyMessage msg) {
    final senderHex = _pubkeyToHex(senderPubkey);
    final readyHex = _pubkeyToHex(msg.peerPubkey);

    if (senderHex == readyHex) {
      final counterpart = _pendingPunchCounterparts.remove(senderHex);
      if (counterpart != null) {
        final counterpartHex = _pubkeyToHex(counterpart);
        _log('Forwarding punch ready from ${readyHex.substring(0, 8)}... '
            'to ${counterpartHex.substring(0, 8)}...');
        sendSignaling?.call(counterpart, codec.encode(msg));
        return;
      }
    }

    _log('Unmatched punch ready from ${senderHex.substring(0, 8)}... '
        'for ${readyHex.substring(0, 8)}...');
  }

  /// Called when the owner sends their friend list. Replaces the anchor's
  /// entire friend list with the owner's. Only the owner can do this.
  void _handleFriendsSync(
    Uint8List senderPubkey,
    String senderHex,
    FriendsSyncMessage msg,
  ) {
    if (senderHex != peerTable.ownerPubkeyHex) {
      _log('FRIENDS_SYNC from non-owner ${senderHex.substring(0, 8)}... — rejected');
      return;
    }

    // Clear existing friends (except owner) and replace with the new list.
    final oldFriends = peerTable.friendPubkeyHexes.toSet();

    // Remove friends not in the new list (except owner)
    for (final hex in oldFriends) {
      if (hex == peerTable.ownerPubkeyHex) continue;
      final stillFriend = msg.friends.any((f) => _pubkeyToHex(f.pubkey) == hex);
      if (!stillFriend) {
        peerTable.removeFriend(hex);
        addressTable.remove(hex);
      }
    }

    // Add new friends
    for (final entry in msg.friends) {
      final hex = _pubkeyToHex(entry.pubkey);
      peerTable.addFriend(hex, nickname: entry.nickname);
    }

    _log('Friend list synced from owner: ${msg.friends.length} friends');
    for (final entry in msg.friends) {
      final hex = _pubkeyToHex(entry.pubkey);
      _log('  ${entry.nickname} (${hex.substring(0, 8)}...)');
    }

    // Notify server to persist the updated friend list
    onFriendsSynced?.call();
  }

  /// Called after FRIENDS_SYNC is processed — server should persist the list.
  void Function()? onFriendsSynced;

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static ({String ip, int port})? _parseAddress(String addr) {
    if (addr.startsWith('[')) {
      final closeBracket = addr.indexOf(']');
      if (closeBracket < 0) return null;
      final ipStr = addr.substring(1, closeBracket);
      final afterBracket = addr.substring(closeBracket + 1);
      if (!afterBracket.startsWith(':')) return null;
      final port = int.tryParse(afterBracket.substring(1));
      if (port == null) return null;
      return (ip: ipStr, port: port);
    } else {
      final lastColon = addr.lastIndexOf(':');
      if (lastColon < 0) return null;
      final ipStr = addr.substring(0, lastColon);
      final port = int.tryParse(addr.substring(lastColon + 1));
      if (port == null) return null;
      if (ipStr.contains(':')) return null;
      return (ip: ipStr, port: port);
    }
  }

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[$ts] $message');
  }
}
