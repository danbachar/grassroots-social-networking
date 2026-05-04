import 'dart:typed_data';

import 'address_table.dart';
import 'peer_table.dart';
import 'protocol.dart';
import 'signaling_codec.dart';

/// Handles all signaling logic for the rendezvous agent.
///
/// Spec-aligned reconnection protocol:
/// - Agent A (whose IP changed) sends RECONNECT(targetPubkey=B) to S.
/// - Agent B (who detected A went silent) sends AVAILABLE(targetPubkey=A) to S.
/// - S observes each agent's source IP/port from the cold-call packet and
///   matches A's RECONNECT against B's AVAILABLE. On match, S sends each side
///   a PUNCH_INITIATE carrying the other side's observed address.
///
/// Friendship-proof verification is intentionally deferred — for now, the
/// server matches any signed RECONNECT/AVAILABLE pair. This is safe for a
/// closed deployment but must be tightened before federation.
///
/// Responsibilities:
/// - Match RECONNECT with AVAILABLE on (sender, target) pubkey pairs.
/// - Coordinate hole-punches by sending PUNCH_INITIATE to both peers with
///   their counterpart's observed address.
/// - Forward PUNCH_READY between counterparts.
/// - Reflect observed addresses back via ADDR_REFLECT (triggered by ANNOUNCE).
class SignalingHandler {
  final Protocol protocol;
  final PeerTable peerTable;
  final AddressTable addressTable;
  final SignalingCodec codec;

  /// Pending RECONNECT/AVAILABLE requests, keyed by `senderHex|targetHex`.
  /// The first request to arrive waits here until the counterpart's request
  /// arrives with the inverse key (`targetHex|senderHex`).
  final Map<String, _PendingRendezvous> _pending = {};

  /// When coordinating a punch, remember the counterpart for PUNCH_READY forwarding.
  final Map<String, Uint8List> _pendingPunchCounterparts = {};

  /// Recently-coordinated punch sessions, keyed by canonical (sorted) pubkey
  /// pair. Lets us drop duplicate match attempts so a redundant
  /// RECONNECT/AVAILABLE arriving during a punch doesn't trigger a second
  /// round of PUNCH_INITIATE.
  final Map<String, DateTime> _recentPunchCoordinations = {};

  /// Window during which a repeated coordination request for the same
  /// unordered pair is dropped. Short enough to recover from a real retry
  /// after genuine failure, long enough to absorb a simultaneous initiate.
  static const _punchCoordinationCooldown = Duration(seconds: 15);

  /// How long an unmatched RECONNECT/AVAILABLE waits for its counterpart.
  static const _pendingExpiry = Duration(seconds: 30);

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
  /// Records the peer as verified and reflects its observed address back.
  /// Address-table entries are not touched here — they are owned by the
  /// anchor's live-connection tracking (`_trackPeerConnection` /
  /// peer-disconnect handlers) so they always match the actual live session
  /// and never flip-flop to stale observations (raw packets, zombie sockets).
  void processAnnounce(
    AnnounceData data, {
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = data.pubkeyHex;

    // Register the peer as verified (they sent a valid signed ANNOUNCE)
    peerTable.addVerified(senderHex, nickname: data.nickname);

    // Update peer table with ANNOUNCE data
    peerTable.upsert(
      publicKey: data.publicKey,
      nickname: data.nickname,
      pubkeyHex: senderHex,
      udpAddress: data.udpAddress,
    );

    // Reflect observed address back to the peer
    if (observedIp != null && observedPort != null) {
      final reflect = AddrReflectMessage(ip: observedIp, port: observedPort);
      sendSignaling?.call(data.publicKey, codec.encode(reflect));
    }
  }

  /// Process an incoming signaling packet.
  void processSignaling(
    Uint8List senderPubkey,
    Uint8List payload, {
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = _pubkeyToHex(senderPubkey);

    SignalingMessage msg;
    try {
      msg = codec.decode(payload);
    } catch (e) {
      _log(
          'Failed to decode signaling from ${senderHex.substring(0, 8)}...: $e');
      return;
    }

    final senderName = peerTable.lookupVerified(senderHex)?.nickname ??
        senderHex.substring(0, 8);
    _log('Signaling from $senderName: ${msg.runtimeType}');

    switch (msg) {
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
      case PunchReadyMessage():
        _handlePunchReady(senderPubkey, msg);
      case PunchInitiateMessage():
        _log('Ignoring PunchInitiate (server is well-connected)');
      case AddrReflectMessage():
        _log('Ignoring AddrReflect (server knows its own address)');
      case RvListMessage():
        _log('Ignoring RvList (server is not part of the social graph)');
    }
  }

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
      _log('Dropping $intent from ${senderHex.substring(0, 8)}... — '
          'cannot observe source address');
      return;
    }

    if (senderHex == targetHex) {
      _log('Dropping $intent from ${senderHex.substring(0, 8)}... — '
          'sender targeting itself');
      return;
    }

    // Record sender's currently-observed address. Live source IP/port is the
    // source of truth — not stale ANNOUNCE state.
    addressTable.register(senderHex, observedIp, observedPort);

    final now = DateTime.now();
    _pruneExpiredPending(now);
    _pruneRecentPunchCoordinations(now);

    final senderName = peerTable.lookupVerified(senderHex)?.nickname ??
        senderHex.substring(0, 8);
    final targetName = peerTable.lookupVerified(targetHex)?.nickname ??
        targetHex.substring(0, 8);

    // Drop duplicate coordination attempts inside the cooldown window —
    // both sides may keep retrying while the punch is still in flight.
    final sessionKey = _punchSessionKey(senderHex, targetHex);
    final lastCoordinated = _recentPunchCoordinations[sessionKey];
    if (lastCoordinated != null &&
        now.difference(lastCoordinated) < _punchCoordinationCooldown) {
      _log('Dropping duplicate $intent ${senderHex.substring(0, 8)}...'
          ' ↔ ${targetHex.substring(0, 8)}... — already coordinated '
          '${now.difference(lastCoordinated).inMilliseconds}ms ago');
      return;
    }

    // Look for the counterpart's pending request.
    final counterpartKey = _pendingKey(targetHex, senderHex);
    final counterpart = _pending.remove(counterpartKey);

    if (counterpart == null) {
      // No counterpart yet — store this request and wait.
      _pending[_pendingKey(senderHex, targetHex)] = _PendingRendezvous(
        senderPubkey: senderPubkey,
        targetHex: targetHex,
        ip: observedIp,
        port: observedPort,
        intent: intent,
        timestamp: now,
      );
      _log('Stored $intent: $senderName($observedIp:$observedPort) '
          '→ $targetName, awaiting counterpart');
      return;
    }

    // Match found — coordinate the punch.
    _recentPunchCoordinations[sessionKey] = now;
    _pendingPunchCounterparts[senderHex] = counterpart.senderPubkey;
    _pendingPunchCounterparts[targetHex] = senderPubkey;

    _log('Coordinating hole-punch (${counterpart.intent} × $intent): '
        '$targetName(${counterpart.ip}:${counterpart.port}) <-> '
        '$senderName($observedIp:$observedPort)');

    // Tell sender to punch toward the counterpart's observed address.
    final initiateToSender = PunchInitiateMessage(
      peerPubkey: counterpart.senderPubkey,
      ip: counterpart.ip,
      port: counterpart.port,
    );
    sendSignaling?.call(senderPubkey, codec.encode(initiateToSender));

    // Tell counterpart to punch toward the sender's observed address.
    final initiateToCounterpart = PunchInitiateMessage(
      peerPubkey: senderPubkey,
      ip: observedIp,
      port: observedPort,
    );
    sendSignaling?.call(counterpart.senderPubkey, codec.encode(initiateToCounterpart));
  }

  void _handlePunchReady(Uint8List senderPubkey, PunchReadyMessage msg) {
    final senderHex = _pubkeyToHex(senderPubkey);

    final counterpart = _pendingPunchCounterparts.remove(senderHex);
    if (counterpart != null) {
      final counterpartHex = _pubkeyToHex(counterpart);
      _log('Forwarding punch ready from ${senderHex.substring(0, 8)}... '
          'to ${counterpartHex.substring(0, 8)}...');
      sendSignaling?.call(counterpart, codec.encode(msg));
      return;
    }

    _log('Unmatched punch ready from ${senderHex.substring(0, 8)}... '
        'for ${_pubkeyToHex(msg.peerPubkey).substring(0, 8)}...');
  }

  // ===== Helpers =====

  static String _pendingKey(String senderHex, String targetHex) =>
      '$senderHex|$targetHex';

  /// Canonical (order-independent) key for a punch session between two peers.
  static String _punchSessionKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  void _pruneExpiredPending(DateTime now) {
    _pending.removeWhere(
      (_, entry) => now.difference(entry.timestamp) >= _pendingExpiry,
    );
  }

  void _pruneRecentPunchCoordinations(DateTime now) {
    _recentPunchCoordinations.removeWhere(
      (_, ts) => now.difference(ts) >= _punchCoordinationCooldown,
    );
  }

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[$ts] $message');
  }
}

class _PendingRendezvous {
  final Uint8List senderPubkey;
  final String targetHex;
  final String ip;
  final int port;
  final String intent;
  final DateTime timestamp;

  _PendingRendezvous({
    required this.senderPubkey,
    required this.targetHex,
    required this.ip,
    required this.port,
    required this.intent,
    required this.timestamp,
  });
}
