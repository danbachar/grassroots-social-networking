import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';
import '../mesh/bloom_filter.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../protocol/protocol_handler.dart';
import '../store/app_state.dart';
import '../store/peers_actions.dart';
import '../store/peers_state.dart';

/// Routes incoming packets from all transports to the appropriate handlers.
///
/// Responsibilities:
/// - Signature verification (drops invalid packets)
/// - Packet deduplication (via BloomFilter)
/// - ANNOUNCE decoding and Redux dispatch
/// - MESSAGE targeting (is-for-us check)
/// - Callback dispatch to application layer
///
/// All transports feed into [processPacket] — one entry point, one format.
class MessageRouter {
  final Logger _log = Logger();

  final BitchatIdentity identity;
  final Store<AppState> store;
  final ProtocolHandler protocolHandler;
  final BloomFilter _seenPackets = BloomFilter();

  /// Called when a message is received
  void Function(String id, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;

  /// Called when an ACK is received (delivery confirmation)
  void Function(String messageId)? onAckReceived;

  /// Called when a read receipt is received
  void Function(String messageId)? onReadReceiptReceived;

  /// Called when a peer ANNOUNCE is processed (new or updated peer)
  void Function(AnnounceData data, PeerTransport transport,
      {bool isNew, String? previousLibp2pAddress})? onPeerAnnounced;

  /// Called when a message needs an ACK sent back to the sender
  void Function(PeerTransport transport, String peerId, String messageId)?
      onAckRequested;

  /// Convenience accessor for peers state
  PeersState get _peersState => store.state.peers;

  MessageRouter({
    required this.identity,
    required this.store,
    required this.protocolHandler,
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
    String? libp2pPeerId,
    int rssi = -100,
  }) async {
    // Verify signature — drop invalid packets
    final isValid = await protocolHandler.verifyPacket(packet);
    if (!isValid) {
      _log.w('Dropping packet with invalid signature (type: ${packet.type})');
      return;
    }

    // ANNOUNCE always processed (peer may have updated info)
    if (packet.type == PacketType.announce) {
      _handleAnnounce(
        packet,
        transport: transport,
        bleDeviceId: bleDeviceId,
        bleRole: bleRole,
        libp2pPeerId: libp2pPeerId,
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
        _handleMessage(packet, transport: transport, libp2pPeerId: libp2pPeerId);
      case PacketType.ack:
        _handleAck(packet);
      case PacketType.nack:
        break;
      case PacketType.readReceipt:
        _handleReadReceipt(packet);
    }
  }

  // ===== Handlers =====

  void _handleAnnounce(
    BitchatPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    BleRole? bleRole,
    String? libp2pPeerId,
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
        // This handles non-BLE transports (e.g., libp2p) where the peer is also
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

    final existingPeer = _peersState.getPeerByPubkey(pubkey);
    final isNew = existingPeer == null;
    final previousLibp2pAddress = existingPeer?.libp2pAddress;

    // LibP2P-specific: use peerId as fallback address
    var libp2pAddresses = data.libp2pAddresses;
    if (transport == PeerTransport.libp2p && libp2pAddresses.isEmpty && libp2pPeerId != null) {
      libp2pAddresses = [libp2pPeerId];
    }

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
      libp2pAddresses: libp2pAddresses,
    ));

    _log.i(
        'Peer ${isNew ? "connected" : "updated"}: ${data.nickname} via ${transport.name}'
        '${libp2pAddresses.isNotEmpty ? ", ${libp2pAddresses.length} libp2p addrs" : ""}'
        '${previousLibp2pAddress != null ? ", prevAddr=${previousLibp2pAddress.substring(0, previousLibp2pAddress.length.clamp(0, 30))}..." : ""}');
    if (libp2pAddresses.isNotEmpty) {
      _log.d('  ANNOUNCE addresses: ${libp2pAddresses.join(", ")}');
    }

    onPeerAnnounced?.call(data, transport,
        isNew: isNew, previousLibp2pAddress: previousLibp2pAddress);
  }

  void _handleMessage(
    BitchatPacket packet, {
    required PeerTransport transport,
    String? libp2pPeerId,
  }) {
    if (!_isForUs(packet)) return;
    onMessageReceived?.call(
        packet.packetId, packet.senderPubkey, packet.payload);
    // Send ACK back for libp2p (delivery confirmation)
    if (transport == PeerTransport.libp2p && libp2pPeerId != null) {
      onAckRequested?.call(transport, libp2pPeerId, packet.packetId);
    }
  }

  void _handleAck(BitchatPacket packet) {
    if (packet.payload.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(packet.payload);
      // Validate: message IDs are short alphanumeric strings (UUID v4 prefix)
      if (messageId.length > 36) {
        _log.w('Ignoring ACK with invalid message ID length: ${messageId.length}');
        return;
      }
      onAckReceived?.call(messageId);
    } catch (e) {
      _log.w('Failed to decode ACK payload: $e');
    }
  }

  void _handleReadReceipt(BitchatPacket packet) {
    if (packet.payload.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(packet.payload);
      if (messageId.length > 36) {
        _log.w('Ignoring read receipt with invalid message ID length: ${messageId.length}');
        return;
      }
      onReadReceiptReceived?.call(messageId);
    } catch (e) {
      _log.w('Failed to decode read receipt payload: $e');
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
