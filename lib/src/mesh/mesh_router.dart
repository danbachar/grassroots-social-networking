import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:cryptography/cryptography.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../models/identity.dart';
import 'bloom_filter.dart';
import 'fragment_handler.dart';
import 'store_forward.dart';

/// Callback type for sending packets over BLE
typedef SendPacketCallback = Future<bool> Function(
    Uint8List recipientPubkey, Uint8List data);

/// Callback type for broadcasting packets to all connected peers
typedef BroadcastCallback = Future<void> Function(Uint8List data,
    {Uint8List? excludePeer});

/// Callback type for delivering received messages to the application layer (GSG)
typedef MessageReceivedCallback = void Function(
    Uint8List senderPubkey, Uint8List payload);

/// Callback for peer discovery events
typedef PeerEventCallback = void Function(Peer peer);

/// The mesh router handles:
/// - Packet deduplication (Bloom filter)
/// - TTL-based routing and relay
/// - Fragmentation of large messages
/// - Store-and-forward for offline peers
/// - ANNOUNCE handling for peer identity
class MeshRouter {
  final Logger _log = Logger();
  
  /// Our identity
  final BitchatIdentity identity;
  
  /// Bloom filter for deduplication
  final BloomFilter _seenPackets = BloomFilter();
  
  /// Fragment handler for large messages
  final FragmentHandler _fragmentHandler = FragmentHandler();
  
  /// Store-and-forward cache for offline peers
  final StoreForwardCache _storeForward = StoreForwardCache();
  
  /// Known peers, keyed by pubkey hex
  final Map<String, Peer> _peers = {};
  
  /// Callback to send a packet to a specific peer
  SendPacketCallback? onSendPacket;
  
  /// Callback to broadcast to all connected peers
  BroadcastCallback? onBroadcast;
  
  /// Callback when an application message is received
  MessageReceivedCallback? onMessageReceived;
  
  /// Callback when a new peer is discovered
  PeerEventCallback? onPeerConnected;
  
  /// Callback when a peer sends an ANNOUNCE update
  PeerEventCallback? onPeerUpdated;
  
  /// Callback when a peer disconnects
  PeerEventCallback? onPeerDisconnected;
  
  /// Protocol version for ANNOUNCE
  static const int protocolVersion = 1;
  
  MeshRouter({required this.identity});
  
  /// Get all known peers
  List<Peer> get peers => _peers.values.toList();
  
  /// Get connected peers only
  List<Peer> get connectedPeers => _peers.values
      .where((p) => p.connectionState == PeerConnectionState.connected)
      .toList();
  
  /// Check if a peer is reachable
  bool isPeerReachable(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    return peer?.isReachable ?? false;
  }
  
  /// Get peer by public key
  Peer? getPeer(Uint8List pubkey) => _peers[_pubkeyToHex(pubkey)];
  
  // ===== Outbound =====
  
  /// Send a message to a specific recipient.
  /// Handles fragmentation if needed.
  Future<bool> sendMessage({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    int ttl = BitchatPacket.defaultTtl,
  }) async {
    // Check if fragmentation needed
    if (_fragmentHandler.needsFragmentation(payload)) {
      return _sendFragmented(
        payload: payload,
        recipientPubkey: recipientPubkey,
        ttl: ttl,
      );
    }

    // Create single packet
    final packet = BitchatPacket(
      type: PacketType.message,
      ttl: ttl,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Placeholder
    );
    
    // Sign the packet
    await _signPacket(packet);
    
    return _sendPacket(packet, recipientPubkey);
  }
  
  /// Broadcast a message to all peers
  Future<void> broadcastMessage({
    required Uint8List payload,
    int ttl = BitchatPacket.defaultTtl,
  }) async {
    if (_fragmentHandler.needsFragmentation(payload)) {
      await _broadcastFragmented(payload: payload, ttl: ttl);
      return;
    }

    final packet = BitchatPacket(
      type: PacketType.message,
      ttl: ttl,
      senderPubkey: identity.publicKey,
      payload: payload,
      signature: Uint8List(64), // Placeholder
    );
    
    // Sign packet
    await _signPacket(packet);
    
    // Mark as seen (don't re-process our own broadcast)
    _seenPackets.add(packet.packetId);
    
    final data = packet.serialize();
    await onBroadcast?.call(data);
  }
  
  Future<bool> _sendFragmented({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    required int ttl,
  }) async {
    final fragmented = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      ttl: ttl,
    );
    
    // Sign each fragment
    for (final fragment in fragmented.fragments) {
      await _signPacket(fragment);
    }
    
    var success = true;
    for (final fragment in fragmented.fragments) {
      _seenPackets.add(fragment.packetId);
      final sent = await _sendPacket(fragment, recipientPubkey);
      if (!sent) success = false;
      
      // Inter-fragment delay
      await Future.delayed(FragmentHandler.fragmentDelay);
    }
    
    return success;
  }
  
  Future<void> _broadcastFragmented({
    required Uint8List payload,
    required int ttl,
  }) async {
    final fragmented = _fragmentHandler.fragment(
      payload: payload,
      senderPubkey: identity.publicKey,
      ttl: ttl,
    );
    
    for (final fragment in fragmented.fragments) {
      _seenPackets.add(fragment.packetId);
      final data = fragment.serialize();
      await onBroadcast?.call(data);
      await Future.delayed(FragmentHandler.fragmentDelay);
    }
  }
  
  Future<bool> _sendPacket(BitchatPacket packet, Uint8List recipientPubkey) async {
    // Mark as seen
    _seenPackets.add(packet.packetId);
    
    // Check if peer is reachable
    if (!isPeerReachable(recipientPubkey)) {
      // Store for later delivery
      _log.d('Peer offline, caching message: ${packet.packetId}');
      _storeForward.cache(packet);
      return false;
    }
    
    final data = packet.serialize();
    return await onSendPacket?.call(recipientPubkey, data) ?? false;
  }
  
  /// Send ANNOUNCE to a newly connected peer
  Future<void> sendAnnounce(Uint8List peerPubkey) async {
    final payload = _encodeAnnounce(
      pubkey: identity.publicKey,
      nickname: identity.nickname,
      protocolVersion: protocolVersion,
    );
    
    final packet = BitchatPacket(
      type: PacketType.announce,
      ttl: 0, // ANNOUNCE is not relayed
      senderPubkey: identity.publicKey,
      recipientPubkey: peerPubkey,
      payload: payload,
      signature: Uint8List(64), // Placeholder
    );
    
    // Sign packet
    await _signPacket(packet);
    
    final data = packet.serialize();
    await onSendPacket?.call(peerPubkey, data);
  }
  
  // ===== Inbound =====
  
  /// Process an incoming packet from BLE
  void onPacketReceived(Uint8List data, {Uint8List? fromPeer}) {
    try {
      final packet = BitchatPacket.deserialize(data);
      _processPacket(packet, fromPeer: fromPeer);
    } catch (e) {
      _log.e('Failed to deserialize packet: $e');
    }
  }
  
  void _processPacket(BitchatPacket packet, {Uint8List? fromPeer}) {
    // Check for duplicates (except ANNOUNCE which shouldn't be deduplicated)
    if (packet.type != PacketType.announce) {
      if (_seenPackets.checkAndAdd(packet.packetId)) {
        _log.d('Duplicate packet dropped: ${packet.packetId}');
        return;
      }
    }
    
    // TODO: Verify signature
    
    // Handle by type
    switch (packet.type) {
      case PacketType.announce:
        _handleAnnounce(packet);
        break;
        
      case PacketType.message:
        _handleMessage(packet, fromPeer: fromPeer);
        break;
        
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
        _handleFragment(packet, fromPeer: fromPeer);
        break;
        
      case PacketType.ack:
        _handleAck(packet);
        break;
        
      case PacketType.nack:
        _handleNack(packet);
        break;
    }
  }
  
  void _handleAnnounce(BitchatPacket packet) {
    final (pubkey, nickname, version) = _decodeAnnounce(packet.payload);
    final key = _pubkeyToHex(pubkey);
    
    var peer = _peers[key];
    final isNew = peer == null;
    
    // TODO: Determine transport type from router; need to have a router per transport protocol
    if (isNew) {
      peer = Peer(publicKey: pubkey, transport: PeerTransport.bleDirect);
      _peers[key] = peer;
    }
    
    peer.updateFromAnnounce(
      nickname: nickname,
      protocolVersion: version,
      receivedAt: DateTime.now(),
    );
    
    _log.i('Peer ${isNew ? "connected" : "updated"}: ${peer.displayName}');
    
    if (isNew) {
      onPeerConnected?.call(peer);
      
      // Deliver any cached messages
      _deliverCachedMessages(pubkey);
    } else {
      onPeerUpdated?.call(peer);
    }
  }
  
  void _handleMessage(BitchatPacket packet, {Uint8List? fromPeer}) {
    if (_isForUs(packet)) {
      _log.d('Message received for us: ${packet.packetId}');
      onMessageReceived?.call(packet.senderPubkey, packet.payload);
      return;
    }
    
    // Not for us - relay if TTL > 0
    _maybeRelay(packet, fromPeer: fromPeer);
  }
  
  void _handleFragment(BitchatPacket packet, {Uint8List? fromPeer}) {
    // Try to reassemble
    final reassembled = _fragmentHandler.processFragment(packet);
    
    if (reassembled != null) {
      // Fragment complete - create a synthetic message packet
      if (_isForUs(packet)) {
        _log.d('Fragmented message reassembled: ${packet.packetId}');
        onMessageReceived?.call(packet.senderPubkey, reassembled);
      } else {
        // Relay the reassembled message? Or relay fragments?
        // Bitchat relays fragments, not reassembled messages
        // (with TTL=0 on reassembled to prevent re-relay)
      }
    }
    
    // Relay the fragment itself if not for us
    if (!_isForUs(packet)) {
      _maybeRelay(packet, fromPeer: fromPeer);
    }
  }
  
  void _handleAck(BitchatPacket packet) {
    // ACK handling - GSG layer may use this
    _log.d('ACK received: ${packet.packetId}');
  }
  
  void _handleNack(BitchatPacket packet) {
    // NACK handling - GSG layer handles this for blocklace sync
    _log.d('NACK received: ${packet.packetId}');
    onMessageReceived?.call(packet.senderPubkey, packet.payload);
  }
  
  bool _isForUs(BitchatPacket packet) {
    if (packet.isBroadcast) return true;
    
    final recipientHex = _pubkeyToHex(packet.recipientPubkey!);
    final ourHex = _pubkeyToHex(identity.publicKey);
    return recipientHex == ourHex;
  }
  
  void _maybeRelay(BitchatPacket packet, {Uint8List? fromPeer}) {
    if (packet.ttl <= 0) {
      _log.d('TTL expired, not relaying: ${packet.packetId}');
      return;
    }
    
    // Decrement TTL and relay
    final relayPacket = packet.decrementTtl();
    final data = relayPacket.serialize();
    
    _log.d('Relaying packet: ${packet.packetId}, TTL: ${relayPacket.ttl}');
    onBroadcast?.call(data, excludePeer: fromPeer);
  }
  
  void _deliverCachedMessages(Uint8List recipientPubkey) {
    final cached = _storeForward.retrieve(recipientPubkey);
    if (cached.isEmpty) return;
    
    _log.i('Delivering ${cached.length} cached messages to ${_pubkeyToHex(recipientPubkey).substring(0, 8)}');
    
    for (final packet in cached) {
      final data = packet.serialize();
      onSendPacket?.call(recipientPubkey, data);
    }
  }
  
  // ===== Peer management =====
  
  /// Called by BLE layer when a peer connects (before ANNOUNCE)
  void onPeerBleConnected(String bleDeviceId, {int? rssi}) {
    // We don't know the pubkey yet - wait for ANNOUNCE
    _log.d('BLE peer connected: $bleDeviceId');
  }
  
  /// Called by BLE layer when a peer disconnects
  void onPeerBleDisconnected(Uint8List pubkey) {
    final key = _pubkeyToHex(pubkey);
    final peer = _peers[key];
    if (peer != null) {
      peer.markDisconnected();
      _log.i('Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    }
  }
  
  // ===== ANNOUNCE encoding/decoding =====
  
  /// Create ANNOUNCE payload for sending to a new peer
  Uint8List createAnnouncePayload() {
    return _encodeAnnounce(
      pubkey: identity.publicKey,
      nickname: identity.nickname,
      protocolVersion: protocolVersion,
    );
  }
  
  Uint8List _encodeAnnounce({
    required Uint8List pubkey,
    required String nickname,
    required int protocolVersion,
  }) {
    final nicknameBytes = Uint8List.fromList(nickname.codeUnits);
    final buffer = BytesBuilder();
    
    // Pubkey (32 bytes)
    buffer.add(pubkey);
    
    // Protocol version (2 bytes)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());
    
    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);
    
    return buffer.toBytes();
  }
  
  (Uint8List, String, int) _decodeAnnounce(Uint8List data) {
    final pubkey = data.sublist(0, 32);
    final version = ByteData.view(data.buffer, data.offsetInBytes + 32, 2)
        .getUint16(0, Endian.big);
    final nicknameLength = data[34];
    final nickname = String.fromCharCodes(data.sublist(35, 35 + nicknameLength));
    return (Uint8List.fromList(pubkey), nickname, version);
  }
  
  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  
  /// Sign a packet with the identity's private key
  Future<void> _signPacket(BitchatPacket packet) async {
    final algorithm = Ed25519();
    // final keyPair = await algorithm.newKeyPairFromSeed(identity.privateKey.sublist(0, 32));
    
    // Get signable bytes (packet with signature zeroed out)
    final signableBytes = packet.getSignableBytes();
    
    // Sign
    final signature = await algorithm.sign(signableBytes, keyPair: identity.keyPair);
    
    // Update packet signature
    packet.signature = Uint8List.fromList(signature.bytes);
  }
  
  /// Clean up resources
  void dispose() {
    _fragmentHandler.dispose();
    _storeForward.dispose();
    _peers.clear();
  }
}
