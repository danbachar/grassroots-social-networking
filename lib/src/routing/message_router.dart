import 'dart:io';
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
  final BitchatIdentity identity;
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
  void Function(Uint8List senderPubkey, Uint8List payload)? onSignalingReceived;

  /// Called when a verified packet arrives over UDP, providing the sender's
  /// pubkey so the coordinator can map the connection (replacing tempKey-based
  /// identification that previously required ANNOUNCE as the first message).
  void Function(Uint8List senderPubkey, String udpPeerId)? onUdpPeerIdentified;

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
    BitchatPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    BleRole? bleRole,
    String? udpPeerId,
    int rssi = -100,
  }) async {
    // Verify signature — drop invalid packets
    final isValid = await protocolHandler.verifyPacket(packet);
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
        _handleFragment(packet);
      case PacketType.ack:
        _handleAck(packet);
      case PacketType.nack:
        // TODO: handle this
        break;
      case PacketType.readReceipt:
        _handleReadReceipt(packet);
      case PacketType.signaling:
        _handleSignaling(packet);
    }
  }

  // ===== Handlers =====

  void _handleAnnounce(
    BitchatPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    BleRole? bleRole,
    String? udpPeerId,
    int rssi = -100,
  }) {
    final data = protocolHandler.decodeAnnounce(packet.payload);
    final pubkey = data.publicKey;

    int effectiveRssi = rssi;

    // Resolve bleDeviceId from discovered BLE peers.
    // Works for ALL transports: if the peer is nearby via BLE, we find their
    // bleDeviceId by matching their service UUID (derived from pubkey).
    // If the peer is NOT nearby, bleDeviceId stays null — correct behavior.
    String? resolvedBleDeviceId = bleDeviceId;
    BleRole? resolvedBleRole = bleRole;
    DiscoveredPeerState? discoveredPeer;
    if (bleDeviceId != null) {
      discoveredPeer = _peersState.getDiscoveredBlePeer(bleDeviceId);
    }
    if (discoveredPeer == null) {
      final theirServiceUuid = BitchatIdentity.deriveServiceUuid(pubkey);
      discoveredPeer =
          _peersState.findDiscoveredBlePeerByServiceUuid(theirServiceUuid);
      if (discoveredPeer != null && bleDeviceId == null) {
        // Only use scan-discovered device ID when no transport-provided ID exists.
        // This handles non-BLE transports (e.g., UDP) where the peer is also
        // nearby via BLE. When bleDeviceId IS provided (BLE transport), we keep it
        // because Android MAC randomization means the scan-discovered MAC may differ
        // from the actual connected MAC.
        resolvedBleDeviceId = discoveredPeer.transportId;
        // If we found via scan, that means our central discovered them
        resolvedBleRole ??= BleRole.central;
      }
    }
    if (discoveredPeer != null) {
      effectiveRssi = discoveredPeer.rssi;
    }

    final isNew = _peersState.getPeerByPubkey(pubkey) == null;

    // Use the address from the ANNOUNCE payload only.
    // udpPeerId is the sender's hex pubkey, NOT an ip:port address —
    // using it as a fallback would corrupt the peer's stored udpAddress
    // and clear their well-connected status.
    final udpAddress = _normalizeUdpAddress(data.udpAddress);
    final linkLocalAddress = _normalizeLinkLocalAddress(data.linkLocalAddress);

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

    onPeerAnnounced?.call(data, transport, isNew: isNew, udpPeerId: udpPeerId);
  }

  void _handleMessage(
    BitchatPacket packet, {
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

  void _handleFragment(BitchatPacket packet) {
    final reassembled = fragmentHandler.processFragment(packet);
    if (reassembled != null) {
      onMessageReceived?.call(
          packet.packetId, packet.senderPubkey, reassembled);
    }
  }

  void _handleAck(BitchatPacket packet) {
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

  void _handleSignaling(BitchatPacket packet) {
    onSignalingReceived?.call(packet.senderPubkey, packet.payload);
  }

  void _handleReadReceipt(BitchatPacket packet) {
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

  bool _isForUs(BitchatPacket packet) {
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

    final parsed = parseIpv6AddressString(udpAddress);
    if (parsed != null) {
      return parsed.toAddressString();
    }

    final legacyParsed = parseAddressString(udpAddress);
    if (legacyParsed != null &&
        legacyParsed.ip.type != InternetAddressType.IPv6) {
      debugPrint('Ignoring unsupported IPv4 UDP address from ANNOUNCE: '
          '$udpAddress. UDP transport requires IPv6.');
      return null;
    }

    debugPrint('Ignoring malformed UDP address from ANNOUNCE: $udpAddress');
    return null;
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
