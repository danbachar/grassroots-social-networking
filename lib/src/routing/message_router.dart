import 'dart:async';
import 'package:redux/redux.dart';
import '../mesh/bloom_filter.dart';
import '../mesh/dtn_store.dart';
import '../mesh/sync_codec.dart';
import '../trace/trace_logger.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../models/platform.dart';
import '../models/secure_frame.dart';
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
/// - ANNOUNCE self-signature verification (all other packets carry no wire
///   signature and authenticate end-to-end via Noise/trial-decrypt)
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

  /// Wire-packet dedup: "have I already seen this exact wire packet?" — gates
  /// relay/loop prevention, keyed on the outer `packetId`.
  final BloomFilter _seenPackets = BloomFilter();

  /// Delivery dedup: "have I already delivered this logical message to the
  /// app?" — keyed on the inner frame `messageId`. This MUST be a separate set
  /// from [_seenPackets]: a single-packet message is sent with
  /// `packetId == messageId` (see `ProtocolHandler.createMessagePacket`), so
  /// sharing one filter would let the relay-dedup insert of `packetId` poison
  /// the delivery check and the message would be dropped as a "duplicate" on
  /// its very first receipt (ACKed but never shown).
  final BloomFilter _deliveredMessages = BloomFilter();

  /// Store-carry-forward cache: packets relayed for recipients not currently in
  /// range, re-flooded when they reappear (see [flushDtnFor]).
  final DtnStore _dtnStore = DtnStore();

  /// Per-neighbor relay budget (managed-flooding abuse cap). A single inbound
  /// neighbor may have at most [_maxRelaysPerWindow] packets relayed on its
  /// behalf per [_relayWindow]; excess is dropped.
  static const Duration _relayWindow = Duration(seconds: 10);
  static const int _maxRelaysPerWindow = 512;
  final Map<String, _RelayBudget> _relayBudgets = {};

  /// Called when a message is received. [transport] is the transport the packet
  /// actually arrived on — authoritative, taken from the receive path rather
  /// than inferred from peer state.
  void Function(String id, Uint8List senderPubkey, Uint8List payload,
      PeerTransport transport)? onMessageReceived;

  /// Called when an ACK is received (delivery confirmation)
  void Function(String messageId)? onAckReceived;

  /// Called when a read receipt is received
  void Function(String messageId)? onReadReceiptReceived;

  /// Called when a peer ANNOUNCE is processed (new or updated peer).
  /// [udpPeerId] is the transport-level peer identifier (tempKey for incoming
  /// UDP connections) so the coordinator can map it to the peer's pubkey.
  void Function(AnnounceData data, PeerTransport transport,
      {bool isNew, String? udpPeerId})? onPeerAnnounced;

  /// Called when a message needs an ACK sent back to its sender. In the mesh the
  /// ACK is a normal recipient-addressed packet flooded back to [senderPubkey]
  /// (recovered by trial-decrypt), not a reply on the inbound path.
  void Function(Uint8List senderPubkey, String messageId,
      PeerTransport transport)? onAckRequested;

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

  /// Called after signature verification and before a BLE ANNOUNCE is applied.
  /// Return false to reject first contact from that sender.
  bool Function(
    Uint8List senderPubkey, {
    String? bleDeviceId,
    BleRole? bleRole,
  })? shouldAcceptBleAnnounce;

  /// Called when [shouldAcceptBleAnnounce] rejects a verified BLE ANNOUNCE.
  void Function(Uint8List senderPubkey, String? bleDeviceId)?
      onBleAnnounceRejected;

  /// Called when a verified packet arrives over UDP, providing the sender's
  /// pubkey so the coordinator can map the connection (replacing tempKey-based
  /// identification that previously required ANNOUNCE as the first message).
  void Function(Uint8List senderPubkey, String udpPeerId)? onUdpPeerIdentified;

  /// Called when a verified BLE ANNOUNCE identifies the peer behind a path —
  /// fired after the announce has been applied to Redux. The BLE transport
  /// uses it to act on the pair's reverse leg at the authoritative moment
  /// (cancel a doomed dial on iOS, or open the reverse central leg).
  void Function(String pathId, Uint8List pubkey, PeerPlatform platform)?
      onBlePeerIdentified;

  /// Called when a Noise handshake packet arrives. The coordinator owns
  /// session state and sends any handshake response over the same medium.
  Future<void> Function(
    GrassrootsPacket packet,
    PeerTransport transport, {
    String? peerId,
  })? onNoiseHandshakeReceived;

  /// Trial-decrypts a sender-anonymous session-encrypted packet against the
  /// active Noise sessions, returning the cleartext packet plus the recovered
  /// sender pubkey (or null if no session opens it).
  Future<(GrassrootsPacket, Uint8List)?> Function(GrassrootsPacket packet)?
      trialDecrypt;

  /// Relays a packet into the BLE mesh by managed flooding — rebroadcast to all
  /// neighbors except [excludeBlePeerId] (the inbound path). The coordinator
  /// wires this to the BLE transport's broadcast.
  void Function(GrassrootsPacket packet, {String? excludeBlePeerId})? onRelay;

  /// Sends a sync-on-connect packet (offer/request/conveyed custody copy) to
  /// one specific BLE neighbor — directed, never flooded. The coordinator
  /// wires this to the BLE transport's per-device send.
  void Function(GrassrootsPacket packet, String bleDeviceId)? onSyncSend;

  /// Convenience accessor for peers state
  PeersState get _peersState => store.state.peers;

  /// Optional opt-in trace logger (null in tests / when logging is off).
  final TraceLogger? trace;

  MessageRouter({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    required this.fragmentHandler,
    this.trace,
  });

  /// Currently-reachable peer count — the temporal node degree at receipt time.
  int _reachablePeerCount() =>
      _peersState.peers.values.where((p) => p.isReachable).length;

  /// Number of sealed packets currently held in the DTN store-carry-forward
  /// cache (buffer-occupancy trace field).
  int get dtnBufferedCount => _dtnStore.totalCount;

  // ===== Unified Packet Processing =====

  /// Process an incoming packet from any transport.
  ///
  /// ANNOUNCE packets self-authenticate (their payload signature is verified in
  /// [ProtocolHandler.decodeAnnounce]) and bypass deduplication; every other
  /// packet carries no wire signature and is authenticated end-to-end by
  /// trial-decrypt against the active Noise sessions.
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
    // ANNOUNCE: neighbor-local presence, self-authenticating (its payload
    // signature is verified in decodeAnnounce). Never deduped or relayed.
    if (packet.type == PacketType.announce) {
      _handleAnnounce(
        packet,
        transport: transport,
        bleDeviceId: bleDeviceId,
        bleRole: bleRole,
        udpPeerId: udpPeerId,
        rssi: rssi,
      );
      return;
    }

    // Noise handshake: neighbor-local control addressed to us by a dialing
    // neighbor. The coordinator resolves the inbound path -> peer pubkey. Not
    // relayed.
    if (packet.type == PacketType.noiseHandshake) {
      if (!_isForUs(packet)) return;
      await onNoiseHandshakeReceived?.call(
        packet,
        transport,
        peerId: udpPeerId ?? bleDeviceId,
      );
      return;
    }

    // Sync-on-connect (anti-entropy): neighbor-local custody reconciliation.
    // BLE-only — the UDP transport is direct point-to-point and carries no
    // DTN custody. Never relayed (TTL 1), never deduped (each sync packet is
    // acted on exactly where it lands).
    if (packet.type == PacketType.syncOffer ||
        packet.type == PacketType.syncRequest) {
      if (transport != PeerTransport.bleDirect || bleDeviceId == null) return;
      if (packet.type == PacketType.syncOffer) {
        _handleSyncOffer(packet, bleDeviceId);
      } else {
        _handleSyncRequest(packet, bleDeviceId);
      }
      return;
    }

    final forUs = _isForUs(packet);

    // The BloomFilter is the "seen packetId" set: it both prevents relay loops
    // (relay each packet at most once) and gates re-processing.
    final firstSeen = !_seenPackets.checkAndAdd(packet.packetId);

    if (forUs && !firstSeen && (trace?.enabled ?? false)) {
      // A duplicate copy of a packet addressed to us arrived (flooding /
      // retransmit) — the message-duplication signal.
      unawaited(trace!.log({
        'type': 'message',
        'dir': 'dup',
        't': DateTime.now().millisecondsSinceEpoch,
        'messageId': packet.packetId,
        'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
      }));
    }

    if (!forUs) {
      // Open managed flooding: forward the sealed, sender-anonymous packet
      // toward its recipient, unverified and without decrypting. Only the first
      // sighting is relayed; TTL bounds the hop count; a per-neighbor budget
      // caps flooding abuse.
      if (firstSeen && packet.ttl > 1 && _allowRelayFrom(bleDeviceId)) {
        onRelay?.call(
          packet.decrementTtl(),
          excludeBlePeerId:
              transport == PeerTransport.bleDirect ? bleDeviceId : null,
        );

        // Store-carry-forward: if the recipient isn't a currently-reachable
        // peer, cache the sealed packet and re-flood it when they reappear.
        final recipientHex = _recipientHex(packet);
        if (recipientHex != null && !_recipientReachable(packet)) {
          _dtnStore.store(recipientHex, packet);
        }
      }
      return;
    }

    // Addressed to us. Everything besides ANNOUNCE/handshake (handled above) is
    // session-encrypted; trial-decrypt to recover the sender + cleartext.
    if (packet.type != PacketType.secure) {
      debugPrint(
          'Dropping unauthenticated cleartext ${packet.type} addressed to us');
      return;
    }

    final decrypted = await trialDecrypt?.call(packet);
    if (decrypted == null) {
      // No active session can open it (or it is a replay of a packet we already
      // processed — the session's AEAD/nonce check rejects it).
      return;
    }
    final (clear, senderPubkey) = decrypted;

    // A successful decrypt authenticates the sender end-to-end; record liveness.
    if (transport == PeerTransport.udp && udpPeerId != null) {
      onUdpPeerIdentified?.call(senderPubkey, udpPeerId);
      store.dispatch(PeerUdpSeenAction(senderPubkey));
    }
    if (transport == PeerTransport.bleDirect &&
        _peersState.getPeerByPubkey(senderPubkey) != null) {
      // ANY authenticated packet that arrived DIRECT (undecremented TTL —
      // relayed traffic must not refresh a departed neighbour's dead
      // attachment) proves the BLE link is alive. Without this, a marginal
      // link whose ANNOUNCEs get lost is torn down by the 20s stale sweep
      // every cycle even while messages/ACKs are flowing over it.
      if (GrassrootsPacket.defaultTtl - packet.ttl <= 0) {
        store.dispatch(PeerBleSeenAction(senderPubkey));
      }
      if (rssi != null) {
        store.dispatch(
            PeerRssiUpdatedAction(publicKey: senderPubkey, rssi: rssi));
      }
    }

    // The decrypted plaintext is a SecureFrame: it carries the content type and
    // any fragmentation, which the sender-anonymous wire header deliberately
    // does not expose to relays.
    final SecureFrame frame;
    try {
      frame = SecureFrame.decode(clear.payload);
    } on FormatException catch (e) {
      debugPrint('Dropping secure packet with malformed frame: $e');
      return;
    }

    switch (frame.contentType) {
      case ContentType.message:
        _handleMessageFrame(
          frame,
          packet: clear,
          senderPubkey: senderPubkey,
          transport: transport,
        );
      case ContentType.ack:
        _handleAck(frame.chunk);
      case ContentType.readReceipt:
        _handleReadReceipt(frame.chunk);
      case ContentType.signaling:
        _handleSignaling(
          frame.chunk,
          senderPubkey,
          observedIp: observedIp,
          observedPort: observedPort,
        );
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
    // decodeAnnounce verifies the payload signature and throws on a forged or
    // malformed ANNOUNCE — drop those.
    final AnnounceData data;
    try {
      data = protocolHandler.decodeAnnounce(packet.payload);
    } catch (e) {
      debugPrint('Dropping ANNOUNCE with invalid signature/format: $e');
      return;
    }
    final pubkey = data.publicKey;

    // Cold-call trust gate for BLE first contact. The sender identity comes
    // from the (now verified) ANNOUNCE payload, not a packet header.
    if (transport == PeerTransport.bleDirect) {
      final accepted = shouldAcceptBleAnnounce?.call(
            pubkey,
            bleDeviceId: bleDeviceId,
            bleRole: bleRole,
          ) ??
          true;
      if (!accepted) {
        debugPrint('[trust] Dropping BLE ANNOUNCE from '
            '${_pubkeyToHex(pubkey).substring(0, 8)}');
        onBleAnnounceRejected?.call(pubkey, bleDeviceId);
        return;
      }
    }

    // Resolve BLE metadata only for packets that actually arrived over BLE.
    // UDP ANNOUNCEs can coincide with stale scan results; treating those as a
    // live BLE path makes UDP-only friends appear in the Nearby/Connected list.
    final isBleAnnounce = transport == PeerTransport.bleDirect;
    String? resolvedBleDeviceId = isBleAnnounce ? bleDeviceId : null;
    BleRole? resolvedBleRole = isBleAnnounce ? bleRole : null;
    DiscoveredPeerState? discoveredPeer;
    if (isBleAnnounce && bleDeviceId != null) {
      discoveredPeer = _peersState.getDiscoveredBlePeer(bleDeviceId);
    }

    // RSSI source priority for BLE-arrived ANNOUNCEs:
    //   1. Per-payload arrival RSSI (our own radio's measurement on this
    //      packet) — strongest source.
    //   2. Scan-time RSSI for the same pathId — also our own measurement,
    //      just slightly older.
    // Peripheral-only paths have no local measurement (the plugin emits
    // null) and leave effectiveRssi null; the UI shows "-- dBm" until the
    // reverse central dial fills it in.
    int? effectiveRssi;
    if (isBleAnnounce) {
      if (rssi != null) {
        effectiveRssi = rssi;
      } else if (discoveredPeer?.rssi != null) {
        effectiveRssi = discoveredPeer!.rssi;
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
      platform: data.platform,
      willingToFacilitate: data.willingToFacilitate,
      rssi: effectiveRssi,
      transport: transport,
      bleCentralDeviceId: centralId,
      blePeripheralDeviceId: peripheralId,
      udpAddress: udpAddress,
      linkLocalAddress: linkLocalAddress,
      udpAddressCandidates: udpAddressCandidates,
    ));

    // The announce action above already recorded the role attachment; now
    // that Redux reflects it, let the BLE transport act on the reverse leg.
    if (resolvedBleDeviceId != null) {
      onBlePeerIdentified?.call(resolvedBleDeviceId, pubkey, data.platform);
    }

    debugPrint(
        'Peer ${isNew ? "connected" : "updated"}: ${data.nickname} via ${transport.name}'
        '${data.udpAddress != null ? " addr=${data.udpAddress}" : ""}');

    // debugPrint('Peer announced!');

    onPeerAnnounced?.call(data, transport, isNew: isNew, udpPeerId: udpPeerId);
  }

  void _handleMessageFrame(
    SecureFrame frame, {
    required GrassrootsPacket packet,
    required Uint8List senderPubkey,
    required PeerTransport transport,
  }) {
    // Reassemble if fragmented; a single-fragment frame yields its payload
    // immediately. Nothing is delivered until the whole message is present.
    final payload = fragmentHandler.accept(frame);
    if (payload == null) return;

    final messageId = frame.messageId;
    // Deliver each logical message once, keyed on its message id in a dedicated
    // filter. Individual wire packets are deduped separately on their packetId
    // (in [_seenPackets]) for loop/relay prevention — the two namespaces must
    // not share bits, since a single-packet message uses packetId == messageId.
    final firstSeen = !_deliveredMessages.checkAndAdd(messageId);
    if (firstSeen) {
      onMessageReceived?.call(messageId, senderPubkey, payload, transport);
      if (trace?.enabled ?? false) {
        final now = DateTime.now().millisecondsSinceEpoch;
        // The receiver sees how far the packet travelled: the sender starts at
        // defaultTtl and each relay decrements, so hops = the drop.
        final relayHops = GrassrootsPacket.defaultTtl - packet.ttl;
        unawaited(trace!.log({
          'type': 'message',
          't': now,
          'dir': 'recv',
          'messageId': messageId,
          'peer': _pubkeyToHex(senderPubkey),
          'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
          'payloadSize': payload.length,
          'receivedAt': now,
          'relayHops': relayHops,
          'deliveryMethod': relayHops <= 0 ? 'direct' : 'relayed',
          'degreeAtEvent': _reachablePeerCount(),
        }));
      }
    } else {
      debugPrint('Duplicate message $messageId; re-ACKing without re-delivering.');
    }

    // ACK back to the original sender (a recipient-addressed packet flooded
    // through the mesh). Re-ACKing a duplicate lets a sender whose first ACK
    // was lost stop retrying.
    onAckRequested?.call(senderPubkey, messageId, transport);
  }

  void _handleAck(Uint8List chunk) {
    if (chunk.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(chunk);
      // Validate: message IDs are UUID strings (<= 36 chars).
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
    Uint8List chunk,
    Uint8List senderPubkey, {
    String? observedIp,
    int? observedPort,
  }) {
    onSignalingReceived?.call(
      senderPubkey,
      chunk,
      observedIp: observedIp,
      observedPort: observedPort,
    );
  }

  void _handleReadReceipt(Uint8List chunk) {
    if (chunk.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(chunk);
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

  String? _recipientHex(GrassrootsPacket packet) {
    final r = packet.recipientPubkey;
    return r == null ? null : _pubkeyToHex(r);
  }

  bool _recipientReachable(GrassrootsPacket packet) {
    final r = packet.recipientPubkey;
    if (r == null) return false;
    return _peersState.getPeerByPubkey(r)?.isReachable ?? false;
  }

  /// Per-neighbor flooding cap. Returns false when the inbound neighbor has had
  /// too many packets relayed on its behalf this window.
  bool _allowRelayFrom(String? inboundPeerId) {
    if (inboundPeerId == null) return true; // unattributable (e.g. UDP)
    final now = DateTime.now();
    final budget =
        _relayBudgets.putIfAbsent(inboundPeerId, () => _RelayBudget(now));
    if (now.difference(budget.windowStart) > _relayWindow) {
      budget.windowStart = now;
      budget.count = 0;
    }
    if (budget.count >= _maxRelaysPerWindow) return false;
    budget.count++;
    return true;
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

  /// Re-flood any store-carry-forward packets cached for [recipientPubkey] —
  /// called by the coordinator when that recipient reappears (their ANNOUNCE /
  /// peer-connected event). The recipient dedups on their side, so re-delivery
  /// is safe.
  void flushDtnFor(Uint8List recipientPubkey) {
    final cached = _dtnStore.takeFor(_pubkeyToHex(recipientPubkey));
    for (final packet in cached) {
      onRelay?.call(packet);
    }
  }

  // ===== Sync-on-connect (DTN anti-entropy) =====
  //
  // Epidemic custody replication: on meeting a new neighbor, each side offers
  // the packetIds its DTN store carries; the other requests the ones it has
  // not seen; the offerer conveys the stored sealed packets over that link.
  // The conveyed packets enter the neighbor's normal processPacket path
  // (dedup → deliver / relay / DTN-store), so carried messages spread through
  // mobile relays instead of waiting for the recipient itself to appear.
  // Reconciliation operates purely on cleartext packetIds — content stays
  // sealed end-to-end and no custody is ever *transferred*, only replicated.

  /// Build the sync offer packets advertising every packetId currently in the
  /// DTN store (chunked to fit single BLE writes). Empty when carrying
  /// nothing — the common case, costing zero packets.
  List<GrassrootsPacket> buildSyncOffers() {
    final ids = _dtnStore.carriedPacketIds();
    if (ids.isEmpty) return const [];
    return buildSyncPackets(PacketType.syncOffer, ids);
  }

  /// A neighbor offered the packetIds it carries: request the ones our
  /// seen-set lacks. A bloom false positive skips a packet we actually lack —
  /// healed by the next contact or the recipient-triggered flush.
  void _handleSyncOffer(GrassrootsPacket packet, String bleDeviceId) {
    final List<String> offered;
    try {
      offered = decodeSyncIds(packet.payload);
    } on FormatException catch (e) {
      debugPrint('[sync] Malformed offer from $bleDeviceId: $e');
      return;
    }
    final wanted =
        offered.where((id) => !_seenPackets.mightContain(id)).toList();
    if (wanted.isEmpty) return;
    debugPrint(
        '[sync] Requesting ${wanted.length}/${offered.length} offered '
        'packet(s) from $bleDeviceId');
    for (final request in buildSyncPackets(PacketType.syncRequest, wanted)) {
      onSyncSend?.call(request, bleDeviceId);
    }
  }

  /// A neighbor requested packets from our offer: convey each one we still
  /// carry, directed over that link. Conveyance counts against the
  /// requester's per-neighbor relay budget — sync must not be a way around
  /// the flooding cap. Ids expired/evicted since the offer are skipped.
  void _handleSyncRequest(GrassrootsPacket packet, String bleDeviceId) {
    final List<String> requested;
    try {
      requested = decodeSyncIds(packet.payload);
    } on FormatException catch (e) {
      debugPrint('[sync] Malformed request from $bleDeviceId: $e');
      return;
    }
    var conveyed = 0;
    for (final id in requested) {
      final stored = _dtnStore.packetById(id);
      if (stored == null) continue; // expired/evicted since the offer
      if (!_allowRelayFrom(bleDeviceId)) break; // budget exhausted this window
      onSyncSend?.call(stored, bleDeviceId);
      conveyed++;
    }
    if (conveyed > 0) {
      debugPrint(
          '[sync] Conveyed $conveyed/${requested.length} requested '
          'packet(s) to $bleDeviceId');
    }
  }

  // ===== Lifecycle =====

  /// Clean up resources
  void dispose() {
    _seenPackets.clear();
    _deliveredMessages.clear();
    _dtnStore.clear();
    _relayBudgets.clear();
  }
}

/// Per-neighbor relay budget window (managed-flooding abuse cap).
class _RelayBudget {
  DateTime windowStart;
  int count = 0;
  _RelayBudget(this.windowStart);
}
