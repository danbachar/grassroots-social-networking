import 'dart:async';
import 'package:redux/redux.dart';
import '../mesh/bloom_filter.dart';
import '../mesh/dtn_store.dart';
import '../mesh/sync_codec.dart';
import '../trace/experiment_recorder.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
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
/// The authenticated reply context of a sync exchange: the peer a sealed
/// sync frame decrypted under, plus the BLE path it arrived on. Replies
/// (requests, conveyed packets) go back over that same path. BLE only —
/// the buffer is a mesh mechanism and the Internet transport stays direct
/// point-to-point, so a sync frame off UDP is never acted on.
class SyncLink {
  final Uint8List peerPubkey;
  final String bleDeviceId;

  const SyncLink(this.peerPubkey, this.bleDeviceId);
}

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

  /// Store-carry-forward cache: packets held for recipients not currently in
  /// range. Conveyed ONLY through the sync exchange — a peer offers the ids it
  /// carries and the other side requests what its seen-set lacks. Nothing is
  /// ever pushed blindly on connect (see [buildSyncOffers]).
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

  /// DEBUG/TESTBED. A peer broadcast a run start for [expId]. Fired for an
  /// authenticated sender only; acting on it is the coordinator's call.
  void Function(String expId, Uint8List senderPubkey)? onTestbedStart;

  /// DEBUG/TESTBED. A peer's gossiped neighbour list (armed-time only).
  void Function(Uint8List senderPubkey, int seq, List<Uint8List> neighbours)?
      onTestbedNeighbours;

  /// Called when a peer ANNOUNCE is processed (new or updated peer).
  /// [udpPeerId] is the transport-level peer identifier (tempKey for incoming
  /// UDP connections) so the coordinator can map it to the peer's pubkey.
  ///
  /// [bleDeviceId] is the BLE path it arrived on. ANNOUNCE is the moment a
  /// path becomes attributable to a pubkey — it carries the key and arrives
  /// on one link — so passing it through is what lets the trace record that
  /// binding. Without it a topology reconstruction can only learn path->peer
  /// from `drop`, and so loses every link that never dropped.
  void Function(AnnounceData data, PeerTransport transport,
      {bool isNew, String? udpPeerId, String? bleDeviceId})? onPeerAnnounced;

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
  void Function(String pathId, Uint8List pubkey)?
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

  /// Sends a sync-on-connect packet (a conveyed buffered copy) back over
  /// [SyncLink] — directed at that one authenticated peer, never flooded. The
  /// coordinator routes by the link's transport.
  void Function(GrassrootsPacket packet, SyncLink link)? onSyncSend;

  /// Seals a sync control frame ([ContentType.syncOffer]/[ContentType.
  /// syncRequest]) to the link's peer and sends it back over the link. The
  /// coordinator owns the Noise sessions, so sealing happens there.
  void Function(ContentType type, Uint8List payload, SyncLink link)?
      onSyncFrame;

  /// Convenience accessor for peers state
  PeersState get _peersState => store.state.peers;

  /// The identity behind a BLE path id, or null when the path has not been
  /// authenticated yet (no verified ANNOUNCE) or has since rotated its MAC.
  /// Trace-only: it turns a relay record's inbound path into a real topology
  /// EDGE (who handed us this packet), instead of leaving the offline
  /// reconstruction to infer parent-child from timestamps — which is wrong
  /// the moment two relays receive the same flood in parallel.
  String? _peerHexForBleDevice(String? bleDeviceId) {
    if (bleDeviceId == null) return null;
    for (final peer in _peersState.peersList) {
      if (peer.bleCentralDeviceId == bleDeviceId ||
          peer.blePeripheralDeviceId == bleDeviceId) {
        return _pubkeyToHex(peer.publicKey);
      }
    }
    return null;
  }

  /// Optional opt-in trace logger (null in tests / when logging is off).
  final ExperimentRecorder? trace;

  MessageRouter({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    required this.fragmentHandler,
    this.trace,
  }) {
    // Non-ACK exits from the DTN buffer (age expiry, cap evictions) were
    // silent: a custody `store` with no `end` was ambiguous between "still
    // held" and "gone". Now every exit is a custody `end` with a reason.
    _dtnStore.onDrop = (reason, recipientHex, packet) {
      if (!(trace?.active ?? false)) return;
      unawaited(trace!.log({
        'type': 'custody',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'end',
        'reason': reason,
        'packetId': packet.packetId,
        'held': _dtnStore.totalCount,
      }));
    };
  }

  /// One record shape for every loss point. `where` names the subsystem
  /// (relay/decrypt/frame/announce/ack/receipt/sync/…), `reason` the cause;
  /// ids land in [extra] when in scope. Uniform so the analyzer can count
  /// loss by site without per-type parsing.
  void _traceDrop(String where, String reason,
      [Map<String, dynamic> extra = const {}]) {
    if (!(trace?.active ?? false)) return;
    unawaited(trace!.log({
      'type': 'drop',
      't': DateTime.now().millisecondsSinceEpoch,
      'where': where,
      'reason': reason,
      ...extra,
    }));
  }

  /// Currently-reachable peer count — the temporal node degree at receipt time.
  int _reachablePeerCount() =>
      _peersState.peers.values.where((p) => p.isReachable).length;

  /// Number of sealed packets currently held in the DTN store-carry-forward
  /// cache (buffer-occupancy trace field).
  int get dtnBufferedCount => _dtnStore.totalCount;

  /// Distinct recipients / payload bytes in the DTN buffer (occupancy trace).
  int get dtnBufferedRecipients => _dtnStore.recipientCount;
  int get dtnBufferedBytes => _dtnStore.totalBytes;

  /// Store-wide packet ceiling. Anything indexed against the buffer (notably
  /// the sender's messageId → packetIds map) must be sized from this: an index
  /// entry is dead the moment its last packet leaves the store, and no more
  /// than this many packets can be live at once.
  int get dtnCapacity => _dtnStore.maxTotal;

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
    // Receipt instant, for the relay record's rx->tx dwell. Taken before any
    // work so the dwell covers everything this node does to the packet: dedup,
    // trial-decrypt, seal, DTN store, and handing the flood to the transport.
    final rxAt = DateTime.now().millisecondsSinceEpoch;
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


    final forUs = _isForUs(packet);

    // The BloomFilter is the "seen packetId" set: it both prevents relay loops
    // (relay each packet at most once) and gates re-processing.
    final firstSeen = !_seenPackets.checkAndAdd(packet.packetId);

    if (forUs && !firstSeen && (trace?.active ?? false)) {
      // A redundant copy of a packet addressed to us arrived (dual-leg
      // delivery, a re-flood, or a sync-exchange conveyance) and was dropped
      // by
      // the packetId bloom. This is a PACKET-level event: the id is the
      // outer packetId, which is NOT the inner frame messageId — the two
      // live in different namespaces, so never join `dup` against `recv`.
      unawaited(trace!.log({
        'type': 'packetDup',
        't': DateTime.now().millisecondsSinceEpoch,
        'packetId': packet.packetId,
        'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
      }));
    }

    if (!forUs) {
      // Open managed flooding: forward the sealed, sender-anonymous packet
      // toward its recipient, unverified and without decrypting. Only the first
      // sighting is relayed; TTL bounds the hop count; a per-neighbor budget
      // caps flooding abuse.
      if (firstSeen && packet.ttl <= 1) {
        // The flood dies here: hop budget exhausted on a first sighting.
        // Previously fully silent — the one place a multi-hop delivery
        // failure leaves evidence on the node that killed it.
        _traceDrop('relay', 'ttlExpired', {
          'packetId': packet.packetId,
          'fromPeer': _peerHexForBleDevice(bleDeviceId),
        });
      } else if (firstSeen && !_allowRelayFrom(bleDeviceId)) {
        // Refused by the per-neighbour budget: not relayed AND not carried
        // (carry lives inside the relay branch, deliberately).
        _traceDrop('relay', 'rateLimited', {
          'packetId': packet.packetId,
          'fromPeer': _peerHexForBleDevice(bleDeviceId),
        });
      } else if (firstSeen && packet.ttl > 1 && _allowRelayFrom(bleDeviceId)) {
        onRelay?.call(
          packet.decrementTtl(),
          excludeBlePeerId:
              transport == PeerTransport.bleDirect ? bleDeviceId : null,
        );

        // Store-carry-forward: if the recipient isn't a currently-reachable
        // peer, cache the sealed packet and re-flood it when they reappear.
        final recipientHex = _recipientHex(packet);
        final carried = recipientHex != null && !_recipientReachable(packet);
        if (carried) {
          _dtnStore.store(recipientHex, packet);
        }
        if (trace?.active ?? false) {
          // The relay's own view: this node forwarded someone else's sealed
          // packet. Joining these across devices by packetId reconstructs the
          // actual path a message took through the mesh (multi-hop evidence).
          // The envelope is sender-anonymous, so we can only report the
          // neighbour we received FROM — which is exactly the topology edge.
          unawaited(trace!.log({
            'type': 'relay',
            't': DateTime.now().millisecondsSinceEpoch,
            'packetId': packet.packetId,
            'ttlIn': packet.ttl,
            'ttlOut': packet.ttl - 1,
            'hop': GrassrootsPacket.defaultTtl - packet.ttl + 1,
            // No recipient: a relay must not need one. Paths reconstruct by
            // packetId alone (the dedup id, cleartext by necessity); the
            // ENDPOINTS log recipient/messageId, so an offline join still
            // yields who it was for without the mesh carrying that.
            'fromDevice': bleDeviceId,
            // The topology edge: WHO handed us this packet. Null when the
            // path is not yet authenticated — the reconstruction then falls
            // back to time ordering for that hop and says so.
            'fromPeer': _peerHexForBleDevice(bleDeviceId),
            'carried': carried, // entered the DTN memory buffer
            // Time this node held the packet, receipt to forward, on ONE
            // clock. End-to-end latency is the sum of these plus the carry
            // times (custody store->convey) plus the radio time between
            // hops — a decomposition that needs no clock sync between
            // devices, unlike subtracting a send timestamp on one phone from
            // a delivery timestamp on another.
            'dwellMs': DateTime.now().millisecondsSinceEpoch - rxAt,
            'degreeAtEvent': _reachablePeerCount(),
          }));
        }
      } else if ((trace?.active ?? false) && !firstSeen) {
        // A relayed duplicate: the flood reached us again by another path.
        unawaited(trace!.log({
          'type': 'relay',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'dup',
          'packetId': packet.packetId,
          'fromDevice': bleDeviceId,
          'fromPeer': _peerHexForBleDevice(bleDeviceId),
        }));
      }
      return;
    }

    // Addressed to us. Everything besides ANNOUNCE/handshake (handled above) is
    // session-encrypted; trial-decrypt to recover the sender + cleartext.
    if (packet.type != PacketType.secure) {
      debugPrint(
          'Dropping unauthenticated cleartext ${packet.type} addressed to us');
      _traceDrop('cleartext', packet.type.name, {'packetId': packet.packetId});
      return;
    }

    final decrypted = await trialDecrypt?.call(packet);
    if (decrypted == null) {
      // No active session can open it (or it is a replay of a packet we already
      // processed — the session's AEAD/nonce check rejects it). The packetId
      // is already in the seen-set (checkAndAdd ran before decrypt), so the
      // sync-offer filter will refuse to re-request this packet: for the
      // pre-session race this is a REAL loss window until a bloom rotation,
      // and this record is its only evidence.
      _traceDrop('decrypt', 'noSession', {
        'packetId': packet.packetId,
        'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
      });
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
      _traceDrop('frame', 'malformed', {
        'packetId': packet.packetId,
        'peer': _pubkeyToHex(senderPubkey),
      });
      return;
    }

    switch (frame.contentType) {
      case ContentType.message:
        _handleMessageFrame(
          frame,
          packet: clear,
          senderPubkey: senderPubkey,
          transport: transport,
          bleDeviceId: bleDeviceId,
          rxAt: rxAt,
        );
      case ContentType.ack:
        _handleAck(frame.chunk, clear, senderPubkey, transport);
      case ContentType.readReceipt:
        _handleReadReceipt(frame.chunk, clear, senderPubkey, transport);
      case ContentType.signaling:
        _handleSignaling(
          frame.chunk,
          senderPubkey,
          observedIp: observedIp,
          observedPort: observedPort,
        );
      case ContentType.syncOffer:
        // Buffer reconciliation is a MESH mechanism: BLE only. UDP is
        // direct point-to-point and moves nothing out of the buffer — it
        // neither
        // relays for third parties nor delivers held packets, so a sync
        // frame arriving over it is not something we participate in. The
        // reply link carries the authenticated peer (trial decrypt proved
        // it), so replies never depend on a transport-level id lookup.
        if (transport == PeerTransport.bleDirect && bleDeviceId != null) {
          _handleSyncOffer(frame.chunk, SyncLink(senderPubkey, bleDeviceId));
        }
      case ContentType.syncRequest:
        if (transport == PeerTransport.bleDirect && bleDeviceId != null) {
          _handleSyncRequest(
              frame.chunk, SyncLink(senderPubkey, bleDeviceId));
        }
      case ContentType.testbedStart:
        // DEBUG/TESTBED. The sender is authenticated (this decrypted under
        // their session); whether to act is the coordinator's decision — it
        // ignores the signal unless the runner was explicitly armed.
        final expId = String.fromCharCodes(frame.chunk);
        if (trace?.active ?? false) {
          unawaited(trace!.log({
            'type': 'runner',
            't': DateTime.now().millisecondsSinceEpoch,
            'event': 'startRx',
            'exp': expId,
            'peer': _pubkeyToHex(senderPubkey),
          }));
        }
        onTestbedStart?.call(expId, senderPubkey);
      case ContentType.testbedNeighbours:
        // DEBUG/TESTBED. Armed-time only; the coordinator drops it outright
        // once a run is under way, so it can never share the air with a
        // measurement.
        try {
          final (seq, peers) =
              ProtocolHandler.decodeTestbedNeighbours(frame.chunk);
          onTestbedNeighbours?.call(senderPubkey, seq, peers);
        } on FormatException catch (e) {
          _traceDrop('neighbourGossip', 'malformed', {'error': e.message});
        }
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
      _traceDrop('announce', 'invalid', {
        'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
      });
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
        _traceDrop('announce', 'trustRejected', {
          'peer': _pubkeyToHex(pubkey),
        });
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
      onBlePeerIdentified?.call(resolvedBleDeviceId, pubkey);
    }

    debugPrint(
        'Peer ${isNew ? "connected" : "updated"}: ${data.nickname} via ${transport.name}'
        '${data.udpAddress != null ? " addr=${data.udpAddress}" : ""}');

    // debugPrint('Peer announced!');

    onPeerAnnounced?.call(data, transport,
        isNew: isNew, udpPeerId: udpPeerId, bleDeviceId: bleDeviceId);
  }

  void _handleMessageFrame(
    SecureFrame frame, {
    required GrassrootsPacket packet,
    required Uint8List senderPubkey,
    required PeerTransport transport,
    String? bleDeviceId,
    int? rxAt,
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
      if (trace?.active ?? false) {
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
          // The FINAL topology edge: the neighbour that handed us the packet,
          // which is the original sender only on a direct delivery. `peer`
          // above is the end-to-end sender recovered by trial decrypt — the
          // two differ exactly when the message was relayed.
          'fromPeer': _peerHexForBleDevice(bleDeviceId),
          'degreeAtEvent': _reachablePeerCount(),
          // Receipt instant of the LAST packet (taken at processPacket entry,
          // before dedup/decrypt/reassembly). t - rxAt = this node's own
          // processing dwell for the delivery, on one clock — the recipient
          // term of the no-sync latency decomposition. For a fragmented
          // message it covers only the final fragment's arrival.
          if (rxAt != null) 'rxAt': rxAt,
          if (rxAt != null) 'procMs': now - rxAt,
        }));
      }
      // ACK back to the original sender (a recipient-addressed packet flooded
      // through the mesh). Only the first delivery ACKs: a duplicate of an
      // already-delivered message triggers nothing — dedup means drop. A
      // sender whose ACK was lost keeps the message in its buffer until a read
      // receipt confirms it or the buffer's age cap expires.
      onAckRequested?.call(senderPubkey, messageId, transport);
    } else {
      debugPrint('Duplicate message $messageId dropped.');
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'message',
          'dir': 'dup',
          't': DateTime.now().millisecondsSinceEpoch,
          'messageId': messageId, // inner id: joins with `sent`/`recv`
          'peer': _pubkeyToHex(senderPubkey),
          'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
        }));
      }
    }
  }

  void _handleAck(Uint8List chunk, GrassrootsPacket packet,
      Uint8List senderPubkey, PeerTransport transport) {
    if (chunk.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(chunk);
      // Validate: message IDs are UUID strings (<= 36 chars).
      if (messageId.length > 36) {
        debugPrint(
            'Ignoring ACK with invalid message ID length: ${messageId.length}');
        _traceDrop('ack', 'badId', {'packetId': packet.packetId});
        return;
      }
      // The ackPacketId <-> messageId join: relay/packetDup/custody records
      // for the ACK's own mesh journey carry only its packetId — this record
      // ties them to the message being acknowledged, making the ACK's return
      // leg reconstructable exactly like the forward leg.
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'message',
          't': DateTime.now().millisecondsSinceEpoch,
          'dir': 'ackRx',
          'messageId': messageId,
          'packetId': packet.packetId,
          'peer': _pubkeyToHex(senderPubkey),
          'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
        }));
      }
      onAckReceived?.call(messageId);
    } catch (e) {
      debugPrint('Failed to decode ACK payload: $e');
      _traceDrop('ack', 'malformed', {'packetId': packet.packetId});
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

  void _handleReadReceipt(Uint8List chunk, GrassrootsPacket packet,
      Uint8List senderPubkey, PeerTransport transport) {
    if (chunk.isEmpty) return;
    try {
      final messageId = String.fromCharCodes(chunk);
      if (messageId.length > 36) {
        debugPrint(
            'Ignoring read receipt with invalid message ID length: ${messageId.length}');
        _traceDrop('receipt', 'badId', {'packetId': packet.packetId});
        return;
      }
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'message',
          't': DateTime.now().millisecondsSinceEpoch,
          'dir': 'receiptRx',
          'messageId': messageId,
          'packetId': packet.packetId,
          'peer': _pubkeyToHex(senderPubkey),
          'transport': transport == PeerTransport.udp ? 'udp' : 'ble',
        }));
      }
      onReadReceiptReceived?.call(messageId);
    } catch (e) {
      debugPrint('Failed to decode read receipt payload: $e');
      _traceDrop('receipt', 'malformed', {'packetId': packet.packetId});
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

  /// Buffer a self-originated sealed packet — the sender holds its own
  /// outgoing packets exactly as a relay holds a stranger's. Offered in
  /// sync-on-connect,
  /// conveyed to whoever lacks it, and ends only on ACK ([dropFromDtnBuffer])
  /// or age expiry.
  void storeInDtnBuffer(
      Uint8List recipientPubkey, GrassrootsPacket sealedPacket) {
    _dtnStore.store(_pubkeyToHex(recipientPubkey), sealedPacket);
    if (trace?.active ?? false) {
      unawaited(trace!.log({
        'type': 'custody',
        't': DateTime.now().millisecondsSinceEpoch,
        'event': 'store',
        'packetId': sealedPacket.packetId,
        'recipient': _pubkeyToHex(recipientPubkey),
        'held': _dtnStore.totalCount,
      }));
    }
    // Our own sealed packets count as seen: a copy conveyed back to us by a
    // relay must not be re-relayed as a fresh sighting.
    _seenPackets.add(sealedPacket.packetId);
  }

  /// Drop [packetIds] from the DTN memory buffer — the recipient ACKed the
  /// message.
  void dropFromDtnBuffer(Iterable<String> packetIds) {
    for (final id in packetIds) {
      _dtnStore.removeById(id);
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'custody',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'end',
          'packetId': id,
          'held': _dtnStore.totalCount,
        }));
      }
    }
  }

  /// All buffered packets held for [recipientPubkey] (own + relayed). Test
  /// inspection only — in production, buffered packets move exclusively
  /// through the
  /// sync offer/request exchange, never a bulk read.
  @visibleForTesting
  List<GrassrootsPacket> dtnBufferFor(Uint8List recipientPubkey) =>
      _dtnStore.packetsFor(_pubkeyToHex(recipientPubkey));

  /// DEBUG/TESTBED ONLY. Empty the DTN memory buffer (per-step, when a field
  /// plan asks) so one step's undelivered backlog cannot drain into the next
  /// step's measurement window. The seen/delivered blooms are deliberately
  /// KEPT — clearing them would re-deliver packets still in flight.
  void clearDtnBuffer() => _dtnStore.clear();

  // ===== Sync-on-connect (DTN anti-entropy) =====
  //
  // Epidemic replication of the DTN memory buffer: on meeting a new
  // neighbor, each side offers
  // the packetIds its DTN store carries; the other requests the ones it has
  // not seen; the offerer conveys the stored sealed packets over that link.
  // The conveyed packets enter the neighbor's normal processPacket path
  // (dedup → deliver / relay / DTN-store), so carried messages spread through
  // mobile relays instead of waiting for the recipient itself to appear.
  // Reconciliation operates purely on cleartext packetIds — content stays
  // sealed end-to-end and no buffer entry is ever *transferred*, only
  // replicated.

  /// Build the sync offer packets advertising packetIds currently in the DTN
  /// store (chunked to fit single BLE writes). Empty when carrying nothing —
  /// the common case, costing zero packets.
  ///
  List<Uint8List> buildSyncOffers() {
    final ids = _dtnStore.carriedPacketIds();
    if (ids.isEmpty) return const [];
    return buildSyncPayloads(ids);
  }

  /// A neighbor offered the packetIds it carries: request the ones our
  /// seen-set lacks. A bloom false positive skips a packet we actually lack —
  /// healed by the next contact or the recipient-triggered flush.
  void _handleSyncOffer(Uint8List payload, SyncLink link) {
    final List<String> offered;
    try {
      offered = decodeSyncIds(payload);
    } on FormatException catch (e) {
      debugPrint('[sync] Malformed offer from ${link.bleDeviceId}: $e');
      _traceDrop('sync', 'malformedOffer', {'peer': _pubkeyToHex(link.peerPubkey)});
      return;
    }
    final wanted =
        offered.where((id) => !_seenPackets.mightContain(id)).toList();
    if (wanted.isEmpty) return;
    debugPrint(
        '[sync] Requesting ${wanted.length}/${offered.length} offered '
        'packet(s) from ${link.bleDeviceId}');
    for (final payload in buildSyncPayloads(wanted)) {
      onSyncFrame?.call(ContentType.syncRequest, payload, link);
    }
  }

  /// A neighbor requested packets from our offer: convey each one we still
  /// carry, directed over that link. Conveyance counts against the
  /// requester's per-neighbor relay budget — sync must not be a way around
  /// the flooding cap. Ids expired/evicted since the offer are skipped.
  void _handleSyncRequest(Uint8List payload, SyncLink link) {
    final List<String> requested;
    try {
      requested = decodeSyncIds(payload);
    } on FormatException catch (e) {
      debugPrint('[sync] Malformed request from ${link.bleDeviceId}: $e');
      _traceDrop('sync', 'malformedRequest', {'peer': _pubkeyToHex(link.peerPubkey)});
      return;
    }
    var conveyed = 0;
    for (var i = 0; i < requested.length; i++) {
      final id = requested[i];
      final stored = _dtnStore.packetById(id);
      if (stored == null) {
        // Expired/evicted since the offer: the requester never learns, and
        // is healed only by a future contact.
        _traceDrop('sync', 'staleOffer', {'packetId': id});
        continue;
      }
      if (!_allowRelayFrom(link.bleDeviceId)) {
        // Budget exhausted mid-conveyance: everything after this point in
        // the request silently waits for the next sync round.
        _traceDrop('sync', 'budgetExhausted', {
          'remaining': requested.length - i,
          'peer': _pubkeyToHex(link.peerPubkey),
        });
        break;
      }
      onSyncSend?.call(stored, link);
      conveyed++;
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'custody',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'convey',
          'packetId': id,
          'toDevice': link.bleDeviceId,
        }));
      }
    }
    if (conveyed > 0) {
      debugPrint(
          '[sync] Conveyed $conveyed/${requested.length} requested '
          'packet(s) to ${link.bleDeviceId}');
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
