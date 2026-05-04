import 'dart:async';
import 'dart:io';

import 'package:redux/redux.dart';
import 'package:flutter/foundation.dart';

import '../store/app_state.dart';
import '../store/peers_actions.dart';
import '../transport/address_utils.dart';
import 'address_table.dart';
import 'signaling_codec.dart';

/// Orchestrates signaling between peers via trusted rendezvous facilitators.
///
/// ## Reconnection protocol (matches the algorithm in the design spec)
///
/// When agent A's IP changes, A and B reconnect through a rendezvous
/// facilitator S as follows:
/// - A sends RECONNECT(peerPubkey=B) to S. S observes A's source address.
/// - B (on detecting A went silent) sends AVAILABLE(peerPubkey=A) to S. S
///   observes B's source address.
/// - S matches the pair and sends each side a PUNCH_INITIATE carrying the
///   other side's observed address.
/// - Both sides punch their NATs; the deterministic UDX initiator opens the
///   stream once the path is open.
///
/// ## Facilitator roles
///
/// - **Rendezvous server** (bootstrap_anchor): runs the RECONNECT/AVAILABLE
///   matcher. The canonical facilitator implementation lives in
///   `bootstrap_anchor/lib/src/signaling_handler.dart`.
/// - **Well-connected friend** (this client, when reachable directly): can
///   relay direct PUNCH_INITIATE for an already-known friend
///   ([requestDirectPunch]). Acting as a full RECONNECT/AVAILABLE matcher
///   inside the client requires plumbing observed source addresses through
///   the message router — left as a follow-up.
///
/// ## Integration
///
/// The service doesn't send packets directly. Instead, it calls
/// [sendSignaling] which the coordinator provides. This keeps the
/// service transport-agnostic.
class SignalingService {
  final Store<AppState> store;
  final SignalingCodec codec;

  /// Address table for friends we've observed via ANNOUNCE.
  ///
  /// Used to pick a target address for [requestDirectPunch] when we want a
  /// nearby friend to start punching toward our advertised address.
  final AddressTable addressTable = AddressTable();

  /// Timer for periodic stale-entry cleanup in the address table.
  Timer? _staleCleanupTimer;

  /// Pending RECONNECT/AVAILABLE awaiting a counterpart, keyed by
  /// `senderHex|targetHex`. Mirrors the rendezvous server's matcher so a
  /// well-connected client can act as a friends-based rendezvous mediator.
  final Map<String, _PendingRendezvous> _pendingRendezvous = {};

  /// Counterpart map for forwarding PUNCH_READY between peers we coordinated.
  final Map<String, Uint8List> _pendingPunchCounterparts = {};

  /// Recently-coordinated punch sessions, keyed by canonical (sorted) pubkey
  /// pair, to drop duplicate matches inside the cooldown window.
  final Map<String, DateTime> _recentPunchCoordinations = {};

  static const _pendingRendezvousExpiry = Duration(seconds: 30);
  static const _punchCoordinationCooldown = Duration(seconds: 15);

  // ===== Callbacks (set by coordinator) =====

  /// Send a signaling payload wrapped in a BitchatPacket to a specific peer.
  /// The coordinator wraps the payload in a BitchatPacket(type: signaling),
  /// signs it, and sends it via the best available transport.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
      sendSignaling;

  /// Send a signaling payload only over an already-live direct control path.
  /// Used for peer-to-peer punch coordination where falling back to UDP would
  /// re-enter the very path we are trying to establish.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
      sendDirectSignaling;

  /// Send a signaling payload to a specific UDP address — used when fanning
  /// out RECONNECT/AVAILABLE to rendezvous servers we've learned about from
  /// a friend (via RV_LIST) but haven't otherwise registered. The coordinator
  /// resolves the address via [_sendViaUdp].
  Future<bool> Function(
    Uint8List recipientPubkey,
    String address,
    Uint8List signalingPayload,
  )? sendSignalingToAddress;

  /// Fired when a rendezvous facilitator (or direct peer) tells us to start
  /// hole-punching. [readyRecipientPubkey] is where we should send PUNCH_READY
  /// after finishing our local punch — either the facilitator or the peer.
  void Function(
    Uint8List peerPubkey,
    String ip,
    int port,
    Uint8List readyRecipientPubkey,
  )? onPunchInitiate;

  /// Fired when a hole-punch completes and we should connect to the peer.
  /// (Triggered by PUNCH_READY from the other side via the facilitator.)
  void Function(Uint8List peerPubkey)? onPunchReady;

  /// Fired when a rendezvous facilitator reflects our observed public address.
  /// The coordinator should update its public address with this value.
  void Function(String ip, int port)? onAddrReflected;

  SignalingService({
    required this.store,
    this.codec = const SignalingCodec(),
  }) {
    // Clean up stale address table entries every 60 seconds.
    _staleCleanupTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => addressTable.removeStale(const Duration(minutes: 5)),
    );
  }

  // ===== Outgoing API (called by coordinator) =====

  /// Send RECONNECT(peerPubkey=target) to every trusted facilitator.
  ///
  /// Called when this agent's connectivity changed (new public IP) and it
  /// wants to reach [targetPubkey]. The facilitators will match this against
  /// any AVAILABLE the target sends and coordinate a hole-punch.
  ///
  /// Returns the number of facilitators the request was sent to.
  Future<int> fanOutReconnect(Uint8List targetPubkey) async {
    return _fanOutCold(targetPubkey, ReconnectMessage(peerPubkey: targetPubkey),
        intent: 'RECONNECT');
  }

  /// Send AVAILABLE(peerPubkey=target) to the rendezvous facilitators that
  /// the target is known to use.
  ///
  /// Spec §3.5: when B detects A went silent, B contacts *A's* known
  /// rendezvous agents — not B's own. We learn the target's RV list (pubkey
  /// + address) via the RV_LIST signaling exchange. If the target hasn't
  /// told us their list yet, fall back to common well-connected friends as
  /// a friends-based rendezvous mediator.
  ///
  /// Returns the number of facilitators the message was sent to.
  Future<int> fanOutAvailable(Uint8List targetPubkey) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final targetPeer = store.state.peers.getPeerByPubkeyHex(targetHex);

    final payload = codec.encode(AvailableMessage(peerPubkey: targetPubkey));
    var sent = 0;

    // Primary: target's known rendezvous servers (spec-compliant). Send via
    // the address the friend told us — needed for RVs we don't ourselves
    // have configured.
    final rvHexes = <String>[];
    if (targetPeer != null) {
      for (final entry in targetPeer.knownRvServers.entries) {
        final hex = entry.key.toLowerCase();
        if (hex.isEmpty || hex == targetHex) continue;
        rvHexes.add(hex);
      }
      rvHexes.sort();
      for (final hex in rvHexes) {
        final address = targetPeer.knownRvServers[hex]!;
        Uint8List rvPubkey;
        try {
          rvPubkey = _hexToBytes(hex);
        } catch (_) {
          continue;
        }
        final ok = await sendSignalingToAddress?.call(
              rvPubkey,
              address,
              payload,
            ) ??
            false;
        if (ok) {
          sent++;
        } else {
          debugPrint(
            '[AVAILABLE] Could not reach RV ${hex.substring(0, 8)}... at '
            '$address',
          );
        }
      }
    }

    // Fallback: well-connected friends (friends-based rendezvous mediators).
    final wcFriends = <String, Uint8List>{};
    for (final friend in store.state.peers.wellConnectedFriends) {
      final friendHex = _pubkeyToHex(friend.publicKey);
      if (friendHex == targetHex) continue;
      wcFriends.putIfAbsent(friendHex, () => friend.publicKey);
    }
    final wcHexes = wcFriends.keys.toList()..sort();
    for (final hex in wcHexes) {
      final ok = await sendSignaling?.call(wcFriends[hex]!, payload) ?? false;
      if (ok) {
        sent++;
      } else {
        debugPrint(
          '[AVAILABLE] Could not reach WC friend ${hex.substring(0, 8)}...',
        );
      }
    }

    if (sent == 0) {
      debugPrint(
        '[AVAILABLE] No facilitators reached for ${targetHex.substring(0, 8)}'
        ' (RV count=${rvHexes.length}, WC friends=${wcHexes.length})',
      );
    } else {
      debugPrint(
        '[AVAILABLE] Sent for ${targetHex.substring(0, 8)} to '
        '${rvHexes.length} target RV(s) + ${wcHexes.length} WC friend(s)',
      );
    }
    return sent;
  }

  Future<int> _fanOutCold(
    Uint8List targetPubkey,
    SignalingMessage msg, {
    required String intent,
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final facilitators = _trustedFacilitatorPubkeys(excludePubkeyHex: targetHex);
    if (facilitators.isEmpty) {
      debugPrint(
          '[$intent] No trusted facilitators to fan out to for ${targetHex.substring(0, 8)}...');
      return 0;
    }

    final payload = codec.encode(msg);
    debugPrint(
      '[$intent] Fanning out for ${targetHex.substring(0, 8)}... to '
      '${facilitators.length} facilitator(s) (lex-ordered)',
    );

    var sent = 0;
    for (final facilitator in facilitators) {
      final ok = await sendSignaling?.call(facilitator, payload) ?? false;
      if (ok) {
        sent++;
      } else {
        debugPrint(
          '[$intent] Could not reach facilitator '
          '${_pubkeyToHex(facilitator).substring(0, 8)}...',
        );
      }
    }
    return sent;
  }

  /// Send our configured rendezvous server list to a friend so they can
  /// target AVAILABLE at exactly those servers when they detect us silent.
  Future<bool> sendRvList(
    Uint8List recipientPubkey,
    List<RvServerEntry> ownRvServers,
  ) async {
    final msg = RvListMessage(entries: ownRvServers);
    return await sendSignaling?.call(recipientPubkey, codec.encode(msg)) ??
        false;
  }

  /// Directly ask a friend to start punching toward our advertised address.
  ///
  /// This is used when the target peer is already reachable over another
  /// transport such as BLE. Instead of relying on a third relay, we send
  /// PUNCH_INITIATE straight to the target and then start punching locally.
  Future<bool> requestDirectPunch(
    Uint8List targetPubkey, {
    required Uint8List requesterPubkey,
    required String requesterIp,
    required int requesterPort,
    bool requireDirectTransport = false,
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final targetPeer = store.state.peers.getPeerByPubkeyHex(targetHex);
    if (targetPeer == null || !targetPeer.isFriend) {
      debugPrint(
        'Cannot request direct punch from non-friend ${targetHex.substring(0, 8)}...',
      );
      return false;
    }

    final msg = PunchInitiateMessage(
      peerPubkey: requesterPubkey,
      ip: requesterIp,
      port: requesterPort,
    );
    final payload = codec.encode(msg);
    final sendFn = requireDirectTransport ? sendDirectSignaling : sendSignaling;
    final sent = await sendFn?.call(targetPubkey, payload) ?? false;

    if (sent) {
      debugPrint(
        'Direct punch request sent to ${targetHex.substring(0, 8)}... '
        'for $requesterIp:$requesterPort',
      );
    } else {
      debugPrint(
        'Failed to send direct punch request to ${targetHex.substring(0, 8)}...',
      );
    }

    return sent;
  }

  /// Notify the facilitator or peer that our local punch completed.
  Future<bool> sendPunchReady(
    Uint8List recipientPubkey,
    Uint8List readyPeerPubkey, {
    bool requireDirectTransport = false,
  }) async {
    final msg = PunchReadyMessage(peerPubkey: readyPeerPubkey);
    final payload = codec.encode(msg);
    final sendFn = requireDirectTransport ? sendDirectSignaling : sendSignaling;
    return await sendFn?.call(recipientPubkey, payload) ?? false;
  }

  static Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  // ===== Incoming processing (called by MessageRouter via coordinator) =====

  /// Process an incoming signaling packet.
  ///
  /// [senderPubkey] is the authenticated sender from the outer BitchatPacket.
  /// [payload] is the raw signaling payload (type byte + message data).
  /// [observedIp] / [observedPort] carry the UDP source address observed by
  /// the transport layer — used by the client's friends-based rendezvous
  /// matcher when this agent is acting as a facilitator for two friends.
  void processSignaling(
    Uint8List senderPubkey,
    Uint8List payload, {
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = _pubkeyToHex(senderPubkey);
    final senderPeer = store.state.peers.getPeerByPubkeyHex(senderHex);
    if (!_isTrustedSignalingSender(senderHex)) {
      debugPrint(
        'Dropping signaling from untrusted sender '
        '${senderHex.substring(0, 8)}...',
      );
      return;
    }

    SignalingMessage msg;
    try {
      msg = codec.decode(payload);
    } catch (e) {
      debugPrint('Failed to decode signaling message: $e');
      return;
    }

    final senderLabel = senderPeer?.displayName ??
        'facilitator ${senderHex.substring(0, 8)}...';
    debugPrint('Received signaling from $senderLabel: $msg');

    switch (msg) {
      case PunchInitiateMessage():
        _handlePunchInitiate(senderPubkey, msg);
      case PunchReadyMessage():
        _handlePunchReady(senderPubkey, msg);
      case AddrReflectMessage():
        _handleAddrReflect(msg);
      case ReconnectMessage():
        _handleRendezvous(
          senderPubkey: senderPubkey,
          senderHex: senderHex,
          targetPubkey: msg.peerPubkey,
          observedIp: observedIp,
          observedPort: observedPort,
          intent: 'RECONNECT',
        );
      case AvailableMessage():
        _handleRendezvous(
          senderPubkey: senderPubkey,
          senderHex: senderHex,
          targetPubkey: msg.peerPubkey,
          observedIp: observedIp,
          observedPort: observedPort,
          intent: 'AVAILABLE',
        );
      case RvListMessage():
        _handleRvList(senderPubkey, msg);
    }
  }

  void _handleRvList(Uint8List senderPubkey, RvListMessage msg) {
    final servers = <String, String>{};
    for (final entry in msg.entries) {
      if (entry.pubkey.length != 32) continue;
      if (entry.address.trim().isEmpty) continue;
      servers[_pubkeyToHex(entry.pubkey)] = entry.address;
    }
    debugPrint(
      '[rv-list] ${_pubkeyToHex(senderPubkey).substring(0, 8)} advertises '
      '${servers.length} rendezvous server(s)',
    );
    store.dispatch(PeerRvServersUpdatedAction(
      publicKey: senderPubkey,
      rvServers: servers,
    ));
  }

  /// Match RECONNECT(A→B) with AVAILABLE(B→A) and dispatch PUNCH_INITIATE
  /// to both sides — same logic as the rendezvous server, run on a client
  /// acting as a friends-based rendezvous mediator.
  void _handleRendezvous({
    required Uint8List senderPubkey,
    required String senderHex,
    required Uint8List targetPubkey,
    required String? observedIp,
    required int? observedPort,
    required String intent,
  }) {
    final targetHex = _pubkeyToHex(targetPubkey);

    if (observedIp == null || observedPort == null) {
      // TODO(ble-mediator): support BLE-arrived RECONNECT/AVAILABLE for the
      // edge case where an internet-down but BLE-adjacent peer asks us to
      // mediate. Replace this drop with a stored-address fallback:
      //   1. Look up the sender's UDP address — first in `addressTable`
      //      (populated by `processAnnounceFromFriend`), then in
      //      `PeerState.udpAddress` / `udpAddressCandidates`.
      //   2. If found, use that as the synthetic observed source for matching
      //      and continue. Mirrors the spec's friends-based mediation model
      //      (§3.5.2 `punch_to`), where the mediator looks up addresses in
      //      its friends list rather than observing them from the packet.
      //   3. If not found, drop — we have nothing to punch toward.
      // Until then, BLE-arrived signaling is dropped here; the typical UDP
      // path covers RV servers and well-connected friends.
      debugPrint(
        'Dropping $intent from ${senderHex.substring(0, 8)}... — no observed '
        'source (likely arrived over BLE; mediator role requires UDP)',
      );
      return;
    }
    if (senderHex == targetHex) {
      debugPrint('Dropping $intent from ${senderHex.substring(0, 8)}... — '
          'sender targeting itself');
      return;
    }

    final now = DateTime.now();
    _pruneExpiredPendingRendezvous(now);
    _pruneRecentPunchCoordinations(now);

    final sessionKey = _punchSessionKey(senderHex, targetHex);
    final lastCoordinated = _recentPunchCoordinations[sessionKey];
    if (lastCoordinated != null &&
        now.difference(lastCoordinated) < _punchCoordinationCooldown) {
      debugPrint('Dropping duplicate $intent ${senderHex.substring(0, 8)}'
          ' ↔ ${targetHex.substring(0, 8)} — already coordinated '
          '${now.difference(lastCoordinated).inMilliseconds}ms ago');
      return;
    }

    final counterpartKey = _pendingKey(targetHex, senderHex);
    final counterpart = _pendingRendezvous.remove(counterpartKey);

    if (counterpart == null) {
      _pendingRendezvous[_pendingKey(senderHex, targetHex)] =
          _PendingRendezvous(
        senderPubkey: senderPubkey,
        ip: observedIp,
        port: observedPort,
        intent: intent,
        timestamp: now,
      );
      debugPrint(
        '[mediate] Stored $intent: ${senderHex.substring(0, 8)}'
        '($observedIp:$observedPort) → ${targetHex.substring(0, 8)}, '
        'awaiting counterpart',
      );
      return;
    }

    _recentPunchCoordinations[sessionKey] = now;
    _pendingPunchCounterparts[senderHex] = counterpart.senderPubkey;
    _pendingPunchCounterparts[targetHex] = senderPubkey;

    debugPrint(
      '[mediate] Coordinating hole-punch (${counterpart.intent} × $intent): '
      '${targetHex.substring(0, 8)}(${counterpart.ip}:${counterpart.port}) <-> '
      '${senderHex.substring(0, 8)}($observedIp:$observedPort)',
    );

    final initiateToSender = PunchInitiateMessage(
      peerPubkey: counterpart.senderPubkey,
      ip: counterpart.ip,
      port: counterpart.port,
    );
    sendSignaling?.call(senderPubkey, codec.encode(initiateToSender));

    final initiateToCounterpart = PunchInitiateMessage(
      peerPubkey: senderPubkey,
      ip: observedIp,
      port: observedPort,
    );
    sendSignaling?.call(
      counterpart.senderPubkey,
      codec.encode(initiateToCounterpart),
    );
  }

  static String _pendingKey(String senderHex, String targetHex) =>
      '$senderHex|$targetHex';

  static String _punchSessionKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  void _pruneExpiredPendingRendezvous(DateTime now) {
    _pendingRendezvous.removeWhere(
      (_, entry) => now.difference(entry.timestamp) >= _pendingRendezvousExpiry,
    );
  }

  void _pruneRecentPunchCoordinations(DateTime now) {
    _recentPunchCoordinations.removeWhere(
      (_, ts) => now.difference(ts) >= _punchCoordinationCooldown,
    );
  }

  // ===== Incoming handlers =====

  /// Process an ANNOUNCE received over UDP from a friend.
  ///
  /// Records the friend's address candidates in the local address table
  /// (used to pick a punch target for [requestDirectPunch]) and reflects
  /// the observed external address back to the sender.
  void processAnnounceFromFriend(
    Uint8List senderPubkey, {
    String? claimedAddress,
    Iterable<String> claimedAddresses = const [],
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = _pubkeyToHex(senderPubkey);

    final normalizedClaimed = normalizeAddressStrings([
      claimedAddress,
      ...claimedAddresses,
    ]);

    for (final address in normalizedClaimed) {
      final parts = _parseAddress(address);
      if (parts == null) continue;
      addressTable.register(senderHex, parts.ip, parts.port);
    }

    if (observedIp != null && observedPort != null) {
      final observedAddress = AddressInfo(
        InternetAddress(observedIp),
        observedPort,
      ).toAddressString();
      final hasClaimedObserved = normalizedClaimed.contains(observedAddress);
      if (normalizedClaimed.isNotEmpty && !hasClaimedObserved) {
        debugPrint(
          'Address mismatch for ${senderHex.substring(0, 8)}...: '
          'claimed $normalizedClaimed, observed $observedIp:$observedPort — adding observed',
        );
      }
      addressTable.register(senderHex, observedIp, observedPort);
    }

    // Reflect the observed address back to the sender so they can learn
    // their true external address (especially the correct NAT port).
    if (observedIp != null && observedPort != null) {
      final reflect = AddrReflectMessage(ip: observedIp, port: observedPort);
      sendSignaling?.call(senderPubkey, codec.encode(reflect));
    }
  }

  /// Parse an address string in "[ip]:port" or "ip:port" format.
  static ({String ip, int port})? _parseAddress(String addr) {
    String ipStr;
    String portStr;

    if (addr.startsWith('[')) {
      final closeBracket = addr.indexOf(']');
      if (closeBracket < 0) return null;
      ipStr = addr.substring(1, closeBracket);
      final afterBracket = addr.substring(closeBracket + 1);
      if (!afterBracket.startsWith(':')) return null;
      portStr = afterBracket.substring(1);
    } else {
      final lastColon = addr.lastIndexOf(':');
      if (lastColon < 0) return null;
      ipStr = addr.substring(0, lastColon);
      portStr = addr.substring(lastColon + 1);
      if (ipStr.contains(':')) return null;
    }

    final port = int.tryParse(portStr);
    if (port == null) return null;

    return (ip: ipStr, port: port);
  }

  /// Handle PUNCH_INITIATE: a rendezvous facilitator telling us to start punching.
  void _handlePunchInitiate(Uint8List senderPubkey, PunchInitiateMessage msg) {
    debugPrint(
      'Punch initiate: punch toward '
      '${_pubkeyToHex(msg.peerPubkey).substring(0, 8)}... at ${msg.ip}:${msg.port}',
    );
    onPunchInitiate?.call(msg.peerPubkey, msg.ip, msg.port, senderPubkey);
  }

  /// Handle PUNCH_READY: either we coordinated this pair (forward to the
  /// counterpart) or it's addressed to us (fire onPunchReady).
  void _handlePunchReady(Uint8List senderPubkey, PunchReadyMessage msg) {
    final senderHex = _pubkeyToHex(senderPubkey);
    final readyHex = _pubkeyToHex(msg.peerPubkey);

    final counterpart = _pendingPunchCounterparts.remove(senderHex);
    if (counterpart != null) {
      debugPrint(
        '[mediate] Forwarding PUNCH_READY from ${senderHex.substring(0, 8)} '
        'to ${_pubkeyToHex(counterpart).substring(0, 8)}',
      );
      unawaited(sendSignaling?.call(counterpart, codec.encode(msg)));
      return;
    }

    debugPrint('Punch ready from ${readyHex.substring(0, 8)}...');
    onPunchReady?.call(msg.peerPubkey);
  }

  /// Handle ADDR_REFLECT: a facilitator telling us our observed address.
  ///
  /// This is the STUN-equivalent for Bitchat. The facilitator saw our real
  /// NAT-translated address on the incoming UDP connection and is reflecting
  /// it back. We update our public address with this value — it has the
  /// correct external port, unlike our local-port-based guess.
  void _handleAddrReflect(AddrReflectMessage msg) {
    debugPrint('Address reflected by facilitator: ${msg.ip}:${msg.port}');
    onAddrReflected?.call(msg.ip, msg.port);
  }

  // ===== Lifecycle =====

  void dispose() {
    _staleCleanupTimer?.cancel();
    _staleCleanupTimer = null;
    _pendingRendezvous.clear();
    _pendingPunchCounterparts.clear();
    _recentPunchCoordinations.clear();
    addressTable.clear();
  }

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool _isTrustedSignalingSender(String senderHex) {
    final senderPeer = store.state.peers.getPeerByPubkeyHex(senderHex);
    if (senderPeer != null && senderPeer.isFriend) {
      return true;
    }

    for (final server in store.state.settings.configuredRendezvousServers) {
      if (server.pubkeyHex.isNotEmpty &&
          server.pubkeyHex.toLowerCase() == senderHex) {
        return true;
      }
    }

    return false;
  }

  /// Trusted facilitators in deterministic lexicographic order by pubkey hex.
  ///
  /// Both well-connected friends and configured rendezvous servers count as
  /// facilitators. Both sides of a reconnection compute the same ordered
  /// list, so they converge on the same facilitator on retry.
  List<Uint8List> _trustedFacilitatorPubkeys({String? excludePubkeyHex}) {
    final facilitators = <String, Uint8List>{};

    for (final friend in store.state.peers.wellConnectedFriends) {
      final friendHex = _pubkeyToHex(friend.publicKey);
      if (friendHex == excludePubkeyHex) continue;
      facilitators[friendHex] = friend.publicKey;
    }

    for (final server in store.state.settings.configuredRendezvousServers) {
      final normalizedHex = server.pubkeyHex.toLowerCase();
      if (normalizedHex.isEmpty || normalizedHex == excludePubkeyHex) {
        continue;
      }

      try {
        facilitators.putIfAbsent(
          normalizedHex,
          () => _hexToBytes(normalizedHex),
        );
      } catch (e) {
        debugPrint('Ignoring invalid rendezvous pubkey in settings: $e');
      }
    }

    final orderedHexes = facilitators.keys.toList()..sort();
    return [for (final hex in orderedHexes) facilitators[hex]!];
  }
}

class _PendingRendezvous {
  final Uint8List senderPubkey;
  final String ip;
  final int port;
  final String intent;
  final DateTime timestamp;

  _PendingRendezvous({
    required this.senderPubkey,
    required this.ip,
    required this.port,
    required this.intent,
    required this.timestamp,
  });
}
