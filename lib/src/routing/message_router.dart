import 'package:redux/redux.dart';
import '../mesh/bloom_filter.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../protocol/fragment_handler.dart';
import '../protocol/protocol_handler.dart';
import '../store/app_state.dart';
import '../store/peers_actions.dart';
import '../store/peers_state.dart';
import '../transport/address_utils.dart';
import 'package:flutter/foundation.dart';

/// Routes incoming packets from all transports to the appropriate handlers.
///
/// Responsibilities:
/// - Signature verification (drops invalid packets)
/// - Packet deduplication (via BloomFilter)
/// - ANNOUNCE decoding and Redux dispatch
/// - MESSAGE targeting (is-for-us check)
/// - Fragment reassembly delegation
/// - Callback dispatch to application layer
///
/// All transports feed into [processPacket] — one entry point, one format.
class MessageRouter {
  final GrassrootsIdentity identity;
  final Store<AppState> store;
  final ProtocolHandler protocolHandler;
  final FragmentHandler fragmentHandler;
  final BloomFilter _seenPackets = BloomFilter();

  /// Called when a message is received
  void Function(String id, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;

  /// Called when an ACK is received (delivery confirmation)
  void Function(String messageId)? onAckReceived;

  /// Called when a read receipt is received
  void Function(String messageId)? onReadReceiptReceived;

  /// Called when a peer ANNOUNCE is processed (new or updated peer).
  /// [udpPeerId] is the transport-level peer identifier (tempKey for incoming
  /// UDP connections) so the coordinator can map it to the peer's pubkey.
  void Function(AnnounceData data, PeerTransport transport,
      {bool isNew, String? udpPeerId})? onPeerAnnounced;

  /// Called when a message needs an ACK sent back to the sender
  void Function(PeerTransport transport, String? peerId, String messageId)?
      onAckRequested;

  /// Called when a signaling packet is received.
  /// The coordinator routes this to [SignalingService.processSignaling].
  /// [observedIp] / [observedPort] carry the UDP source address observed by
  /// the transport layer (null for BLE-arrived signaling).
  void Function(
    Uint8List senderPubkey,
    Uint8List payload, {
    String? observedIp,
    int? observedPort,
  })? onSignalingReceived;

  /// Called when a verified packet arrives over UDP, providing the sender's
  /// pubkey so the coordinator can map the connection (replacing tempKey-based
  /// identification that previously required ANNOUNCE as the first message).
  void Function(Uint8List senderPubkey, String udpPeerId)? onUdpPeerIdentified;

  /// Called when a signed Noise handshake packet arrives. The coordinator owns
  /// session state and sends any handshake response over the same medium.
  Future<void> Function(
    GrassrootsPacket packet,
    PeerTransport transport, {
    String? peerId,
  })? onNoiseHandshakeReceived;

  /// Decrypts a signed session-encrypted packet before normal routing.
  Future<GrassrootsPacket?> Function(
    GrassrootsPacket packet,
    PeerTransport transport, {
    String? peerId,
  })? decryptSessionPacket;

  /// Convenience accessor for peers state
  PeersState get _peersState => store.state.peers;

  MessageRouter({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    required this.fragmentHandler,
  });

  // ===== Unified Packet Processing =====

  /// Process an incoming packet from any transport.
  ///
  /// All packets are signature-verified before processing.
  /// Invalid signatures are dropped immediately.
  /// ANNOUNCE packets bypass deduplication (always processed).
  Future<void> processPacket(
    GrassrootsPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    BleRole? bleRole,
    String? udpPeerId,
    int? rssi,
    String? observedIp,
    int? observedPort,
  }) async {
    // Verify signature — drop invalid packets.
    // Ed25519 verify is CPU-bound on the main isolate (cryptography package
    // pure-Dart implementation). For fragmented payloads (~315 fragments per
    // 100 KB picture), this dominates receive latency. Log per-packet timing
    // so the cost is visible.
    final verifyStart = DateTime.now();
    final isValid = await protocolHandler.verifyPacket(packet);
    final verifyMs = DateTime.now().difference(verifyStart).inMilliseconds;
    if (verifyMs > 50) {
      debugPrint(
          '[verify] ${packet.type.name} from ${_pubkeyToHex(packet.senderPubkey).substring(0, 8)} took ${verifyMs}ms');
    }
    if (!isValid) {
      debugPrint(
          'Dropping packet with invalid signature (type: ${packet.type})');
      return;
    }

    String? effectiveUdpPeerId = udpPeerId;

    // Map incoming UDP connections from any verified packet's senderPubkey.
    // Previously required ANNOUNCE as the first message on a stream; now any
    // verified packet identifies the sender.
    if (transport == PeerTransport.udp && udpPeerId != null) {
      onUdpPeerIdentified?.call(packet.senderPubkey, udpPeerId);
      effectiveUdpPeerId = _pubkeyToHex(packet.senderPubkey);
    }

    if (packet.type == PacketType.noiseHandshake) {
      await onNoiseHandshakeReceived?.call(
        packet,
        transport,
        peerId: effectiveUdpPeerId ?? bleDeviceId,
      );
      return;
    }

    if (packet.type.isSessionEncrypted) {
      final decrypted = await decryptSessionPacket?.call(
        packet,
        transport,
        peerId: effectiveUdpPeerId ?? bleDeviceId,
      );
      if (decrypted == null) {
        debugPrint('Dropping encrypted packet without session');
        return;
      }
      packet = decrypted;
    }

    // Any verified non-ANNOUNCE packet over UDP counts as liveness traffic
    // for that peer, even if it is an ACK, read receipt, or retransmission.
    if (transport == PeerTransport.udp && packet.type != PacketType.announce) {
      store.dispatch(PeerUdpSeenAction(packet.senderPubkey));
    }

    // Refresh per-packet RSSI on every verified BLE packet from a known peer.
    // The plugin reports `payload.rssi` for every received BLE packet
    // regardless of role, so this keeps the indicator current during
    // conversation traffic (not just on the next advertisement). For ANNOUNCE
    // packets, _handleAnnounce already covers the RSSI update via
    // PeerAnnounceReceivedAction.
    if (transport == PeerTransport.bleDirect &&
        rssi != null &&
        packet.type != PacketType.announce) {
      final peer = _peersState.getPeerByPubkey(packet.senderPubkey);
      if (peer != null) {
        store.dispatch(PeerRssiUpdatedAction(
          publicKey: packet.senderPubkey,
          rssi: rssi,
        ));
      }
    }

    // ANNOUNCE always processed (peer may have updated info)
    if (packet.type == PacketType.announce) {
      _handleAnnounce(
        packet,
        transport: transport,
        bleDeviceId: bleDeviceId,
        bleRole: bleRole,
        udpPeerId: effectiveUdpPeerId,
        rssi: rssi,
      );
      return;
    }

    // Dedup for non-ANNOUNCE packets
    if (_seenPackets.checkAndAdd(packet.packetId)) {
      return;
    }

    switch (packet.type) {
      case PacketType.announce:
        return; // Already handled above
      case PacketType.message:
        // TODO: why do messages have different types than packets?
        _handleMessage(
          packet,
          transport: transport,
          peerId: effectiveUdpPeerId ?? bleDeviceId,
        );
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
        _handleFragment(
          packet,
          transport: transport,
          peerId: effectiveUdpPeerId ?? bleDeviceId,
        );
      case PacketType.ack:
        _handleAck(packet);
      case PacketType.nack:
        // TODO: handle this
        break;
      case PacketType.readReceipt:
        _handleReadReceipt(packet);
      case PacketType.signaling:
        _handleSignaling(
          packet,
          observedIp: observedIp,
          observedPort: observedPort,
        );
      case PacketType.noiseHandshake:
      case PacketType.secureMessage:
      case PacketType.secureFragmentStart:
      case PacketType.secureFragmentContinue:
      case PacketType.secureFragmentEnd:
      case PacketType.secureAck:
      case PacketType.secureNack:
      case PacketType.secureReadReceipt:
      case PacketType.secureSignaling:
        return;
    }
  }

  // ===== Handlers =====

  void _handleAnnounce(
    GrassrootsPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    BleRole? bleRole,
    String? udpPeerId,
    int? rssi,
  }) {
    final data = protocolHandler.decodeAnnounce(packet.payload);
    final pubkey = data.publicKey;

    // Use the per-packet RSSI from the BLE plugin (passed in via `rssi` for BLE
    // ANNOUNCEs; null for UDP ANNOUNCEs). This is always more current than the
    // advertisement RSSI cached on `DiscoveredPeerState`, especially on the
    // peripheral side where our scanner may not have seen the central yet.
    final int? effectiveRssi =
        transport == PeerTransport.bleDirect ? rssi : null;

    // Resolve BLE metadata only for packets that actually arrived over BLE.
    // UDP ANNOUNCEs can coincide with stale scan results; treating those as a
    // live BLE path makes UDP-only friends appear in the Nearby/Connected list.
    final isBleAnnounce = transport == PeerTransport.bleDirect;
    String? resolvedBleDeviceId = isBleAnnounce ? bleDeviceId : null;
    BleRole? resolvedBleRole = isBleAnnounce ? bleRole : null;
    if (isBleAnnounce && bleDeviceId == null) {
      // No transport-provided device ID — try to find one from our scan results
      // by matching on the service UUID derived from their pubkey. (We do NOT
      // use this lookup to source RSSI; the per-packet value above is fresher.)
      final theirServiceUuid = GrassrootsIdentity.deriveServiceUuid(pubkey);
      final discoveredPeer =
          _peersState.findDiscoveredBlePeerByServiceUuid(theirServiceUuid);
      if (discoveredPeer != null) {
        resolvedBleDeviceId = discoveredPeer.transportId;
        // If we found via scan, that means our central discovered them.
        resolvedBleRole ??= BleRole.central;
      }
    }

    final isNew = _peersState.getPeerByPubkey(pubkey) == null;

    // Use the address from the ANNOUNCE payload only.
    // udpPeerId is the sender's hex pubkey, NOT an ip:port address —
    // using it as a fallback would corrupt the peer's stored udpAddress
    // and clear their well-connected status.
    final udpAddress = _normalizeUdpAddress(data.udpAddress);
    final linkLocalAddress = _normalizeLinkLocalAddress(data.linkLocalAddress);
    final udpAddressCandidates = _normalizeUdpAddressCandidates([
      ...data.addressCandidates,
      udpAddress,
      linkLocalAddress,
    ]);

    // Set the correct BLE device ID field based on role
    String? centralId;
    String? peripheralId;
    if (resolvedBleDeviceId != null && resolvedBleRole != null) {
      if (resolvedBleRole == BleRole.central) {
        centralId = resolvedBleDeviceId;
      } else {
        peripheralId = resolvedBleDeviceId;
      }
    }

    store.dispatch(PeerAnnounceReceivedAction(
      publicKey: pubkey,
      nickname: data.nickname,
      protocolVersion: data.protocolVersion,
      rssi: effectiveRssi,
      transport: transport,
      bleCentralDeviceId: centralId,
      blePeripheralDeviceId: peripheralId,
      udpAddress: udpAddress,
      linkLocalAddress: linkLocalAddress,
      udpAddressCandidates: udpAddressCandidates,
    ));

    if (resolvedBleDeviceId != null && resolvedBleRole != null) {
      store.dispatch(AssociateBleDeviceAction(
        publicKey: pubkey,
        deviceId: resolvedBleDeviceId,
        role: resolvedBleRole,
      ));
    }

    debugPrint(
        'Peer ${isNew ? "connected" : "updated"}: ${data.nickname} via ${transport.name}'
        '${data.udpAddress != null ? " addr=${data.udpAddress}" : ""}');

    // debugPrint('Peer announced!');

    onPeerAnnounced?.call(data, transport, isNew: isNew, udpPeerId: udpPeerId);
  }

  void _handleMessage(
    GrassrootsPacket packet, {
    required PeerTransport transport,
    String? peerId,
  }) {
    if (!_isForUs(packet)) return;
    onMessageReceived?.call(
        packet.packetId, packet.senderPubkey, packet.payload);
    // Send ACK back to confirm delivery. The sender waits for this to
    // mark the message as "delivered" (2 checkmarks). Works over both
    // BLE (peerId = bleDeviceId) and UDP (peerId = udpPeerId).
    onAckRequested?.call(transport, peerId, packet.packetId);
  }

  void _handleFragment(
    GrassrootsPacket packet, {
    required PeerTransport transport,
    String? peerId,
  }) {
    final reassembled = fragmentHandler.processFragment(packet);
    if (reassembled == null) return;

    // Reassembly produced the original message's payload bytes. Synthesize
    // a logical MESSAGE packet and route it through `_handleMessage` so the
    // single-packet and fragmented paths share one delivery pipeline:
    //   - `_isForUs` recipient check
    //   - `onMessageReceived` dispatch
    //   - `onAckRequested` round-trip
    //
    // The signature field is zeroed because per-fragment signatures have
    // already been verified upstream in `processPacket`; nothing downstream
    // re-checks the synthetic packet's signature.
    final logical = GrassrootsPacket(
      type: PacketType.message,
      ttl: packet.ttl,
      timestamp: packet.timestamp,
      senderPubkey: packet.senderPubkey,
      recipientPubkey: packet.recipientPubkey,
      payload: reassembled.payload,
      signature: Uint8List(64),
      packetId: reassembled.messageId,
    );
    _handleMessage(logical, transport: transport, peerId: peerId);
  }

  void _handleAck(GrassrootsPacket packet) {
    if (packet.payload.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(packet.payload);
      // Validate: message IDs are short alphanumeric strings (UUID v4 prefix)
      if (messageId.length > 36) {
        debugPrint(
            'Ignoring ACK with invalid message ID length: ${messageId.length}');
        return;
      }
      onAckReceived?.call(messageId);
    } catch (e) {
      debugPrint('Failed to decode ACK payload: $e');
    }
  }

  void _handleSignaling(
    GrassrootsPacket packet, {
    String? observedIp,
    int? observedPort,
  }) {
    onSignalingReceived?.call(
      packet.senderPubkey,
      packet.payload,
      observedIp: observedIp,
      observedPort: observedPort,
    );
  }

  void _handleReadReceipt(GrassrootsPacket packet) {
    if (packet.payload.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(packet.payload);
      if (messageId.length > 36) {
        debugPrint(
            'Ignoring read receipt with invalid message ID length: ${messageId.length}');
        return;
      }
      onReadReceiptReceived?.call(messageId);
    } catch (e) {
      debugPrint('Failed to decode read receipt payload: $e');
    }
  }

  // ===== Helpers =====

  bool _isForUs(GrassrootsPacket packet) {
    if (packet.isBroadcast) return true;
    return _pubkeysEqual(packet.recipientPubkey!, identity.publicKey);
  }

  static bool _pubkeysEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String? _normalizeUdpAddress(String? udpAddress) {
    if (udpAddress == null || udpAddress.isEmpty) return null;

    final parsed = parseAddressString(udpAddress);
    if (parsed != null) return parsed.toAddressString();

    debugPrint('Ignoring malformed UDP address from ANNOUNCE: $udpAddress');
    return null;
  }

  Set<String> _normalizeUdpAddressCandidates(Iterable<String?> addresses) {
    final normalized = <String>{};
    for (final address in addresses) {
      final parsed = _normalizeUdpAddress(address);
      if (parsed != null) {
        normalized.add(parsed);
      }
    }
    return normalized;
  }

  String? _normalizeLinkLocalAddress(String? udpAddress) {
    final normalized = _normalizeUdpAddress(udpAddress);
    if (normalized == null) return null;

    final parsed = parseIpv6AddressString(normalized);
    if (parsed == null) return null;
    if (!parsed.ip.isLinkLocal) {
      debugPrint(
          'Ignoring non-link-local address in ANNOUNCE link-local field: '
          '$udpAddress');
      return null;
    }
    return parsed.toAddressString();
  }

  // ===== Deduplication API =====

  /// Mark a packet ID as seen (e.g., for outgoing packets)
  void markSeen(String packetId) {
    _seenPackets.add(packetId);
  }

  /// Check if a packet ID has been seen before
  bool isDuplicate(String packetId) {
    return _seenPackets.mightContain(packetId);
  }

  // ===== Lifecycle =====

  /// Clean up resources
  void dispose() {
    _seenPackets.clear();
  }
}
