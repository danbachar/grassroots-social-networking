import 'dart:async';
import 'package:redux/redux.dart';
import '../mesh/seen_packets.dart';
import '../mesh/delivered_messages.dart';
import '../mesh/dtn_store.dart';
import '../mesh/gcs_filter.dart';
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
/// - Packet deduplication (via the age-bounded seen-packetId set)
/// - ANNOUNCE decoding and Redux dispatch
/// - MESSAGE targeting (is-for-us check)
/// - Fragment reassembly delegation
/// - Callback dispatch to application layer
///
/// All transports feed into [processPacket] — one entry point, one format.
/// Which transport a sync exchange is running over.
///
/// The distinction is not cosmetic: it decides WHAT may be conveyed on the
/// answer (see [MessageRouter._handleSyncFilter]).
enum SyncTransport {
  /// The BLE mesh. A node conveys anything it holds, for any recipient — that
  /// open relay is what gives the mesh reach beyond direct neighbours.
  ble,

  /// A direct UDX link. A node conveys ONLY packets addressed to the peer on
  /// the other end of it, never third-party transit traffic.
  udx,
}

/// The link a sync exchange runs over.
///
/// [handle] is the transport-level peer id used to send: a BLE device id under
/// [SyncTransport.ble], and the peer's pubkey hex under [SyncTransport.udx]
/// (which is exactly what `UdpTransportService.sendToPeer` keys on, so no
/// lookup table is needed to answer over the Internet).
class SyncLink {
  final Uint8List peerPubkey;
  final String handle;
  final SyncTransport transport;

  const SyncLink.ble(this.peerPubkey, this.handle)
      : transport = SyncTransport.ble;

  const SyncLink.udx(this.peerPubkey, this.handle)
      : transport = SyncTransport.udx;

  bool get isUdx => transport == SyncTransport.udx;
}

class MessageRouter {
  final GrassrootsIdentity identity;
  final Store<AppState> store;
  final ProtocolHandler protocolHandler;
  final FragmentHandler fragmentHandler;

  /// Wire-packet dedup: "have I already seen this exact wire packet?" — gates
  /// relay/loop prevention, keyed on the outer `packetId`. Age-bounded, NOT a
  /// rotating bloom: a wholesale clear under load forgot seen ids and let an
  /// already-relayed packet be re-admitted, re-stored and re-circulated (12x
  /// airtime in the GCS arm). It outlives the DTN buffer for the same reason
  /// [DeliveredMessages] does — a copy can only reach us while a buffer holds
  /// it. See [SeenPackets].
  final SeenPackets _seenPackets = SeenPackets();

  /// Delivery dedup: "have I already delivered this logical message to the
  /// app?" — keyed on the inner frame `messageId`. This MUST be a separate set
  /// from [_seenPackets]: a single-packet message is sent with
  /// `packetId == messageId` (see `ProtocolHandler.createMessagePacket`), so
  /// sharing one filter would let the relay-dedup insert of `packetId` poison
  /// the delivery check and the message would be dropped as a "duplicate" on
  /// its very first receipt (ACKed but never shown).
  final DeliveredMessages _deliveredMessages = DeliveredMessages();

  /// Store-carry-forward cache: packets held for recipients not currently in
  /// range. Conveyed ONLY through the sync exchange — a peer advertises a
  /// compact filter of what it has SEEN and we answer with what that filter
  /// lacks. Nothing is ever pushed blindly on connect (see [buildSyncFilter]).
  /// Over BLE we answer with anything we hold; over UDX, only with packets
  /// addressed to that peer (see [SyncTransport]).
  final DtnStore _dtnStore = DtnStore();

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
  /// identification, so a stream need not open with an ANNOUNCE).
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

  /// Sends a sync-on-connect packet (a conveyed buffered copy) back over
  /// [SyncLink] — directed at that one authenticated peer, never flooded. The
  /// coordinator routes by the link's transport.
  void Function(GrassrootsPacket packet, SyncLink link)? onSyncSend;

  /// Writes a sealed packet on a live link to [recipientPubkey] — the BLE
  /// leg preferred, else a live UDX connection — and reports which transport
  /// carried it, or null when no live link exists (or the write was refused).
  /// Neither arm dials: a link either exists or the packet is buffered.
  /// Injected by the coordinator (which owns the transports); used by
  /// [dispatchOutbound] alone, which makes it the ORIGINATOR's tool: a
  /// carried packet is never written unrequested, it moves only through the
  /// sync exchange.
  Future<PeerTransport?> Function(
      Uint8List recipientPubkey, GrassrootsPacket sealed)? directSend;

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
      // Tell the sender's index first, and unconditionally: this is a
      // correctness path, not a tracing one, so it must not sit behind the
      // `trace.active` return below.
      onBufferedPacketDropped?.call(packet.packetId);
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

  /// A buffered packet left the store WITHOUT an ACK (age expiry or an
  /// eviction). The sender's messageId → packetIds index subscribes to this
  /// so it can forget the entry: an index entry is dead the moment its last
  /// packet leaves the store, and an index that only ever drained on ACK
  /// filled with dead entries and then evicted LIVE ones — which is exactly
  /// what turns ACK-driven buffer release off.
  void Function(String packetId)? onBufferedPacketDropped;

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
    //
    // ANNOUNCE and the Noise handshake are the two cleartext, neighbour-local
    // types that are fragmented to the per-leg BLE MTU on the send side (a
    // friend ANNOUNCE with address candidates overflows the common 247 MTU).
    // The neighbour is the endpoint, so reassemble here before dispatch; the
    // handlers read the ORIGINAL payload with no frag header. A single-fragment
    // set returns immediately; an incomplete one returns null and we wait.
    if (packet.type == PacketType.announce) {
      final whole = _reassembleNeighbour(packet);
      if (whole == null) return;
      _handleAnnounce(
        whole,
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
      final whole = _reassembleNeighbour(packet);
      if (whole == null) return;
      await onNoiseHandshakeReceived?.call(
        whole,
        transport,
        peerId: udpPeerId ?? bleDeviceId,
      );
      return;
    }


    final forUs = _isForUs(packet);

    // Two thresholds, and they are tested against different values because
    // they are different acts. DELIVERING is not a hop: it is judged on the
    // TTL as it arrived, which need only be >= 0, so a packet that reaches
    // the node it is addressed to with nothing left is still delivered.
    // FORWARDING is a hop: it subtracts one first and needs the result above
    // zero, since anything else would put a dead packet on the air.
    if (packet.ttl < 0) {
      _traceDrop('rx', 'ttlExhausted', {
        'packetId': packet.packetId,
        'forUs': forUs,
      });
      return;
    }

    // The seen-packetId set both prevents relay loops (relay each packet at
    // most once) and gates re-processing.
    final firstSeen =
        !_seenPackets.checkAndAdd(packet.packetId, packet.createdAtMs);

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
      // sighting is relayed and TTL bounds the hop count — those two are the
      // whole bound on the flood.
      // A node refuses a relay whose count has ALREADY reached 0; anything
      // above that is accepted, decremented, and forwarded once. So a packet
      // with one hop left is still passed on — it goes out at 0, which is
      // useful precisely because the destination is exempt from this check:
      // that last broadcast can still be accepted by a neighbour who is the
      // recipient. It simply cannot be relayed again after that.
      final relayAllowed = firstSeen && packet.ttl > 0;

      if (firstSeen && packet.ttl <= 0) {
        // The flood dies here: hop budget exhausted on a first sighting.
        // Recorded here: the one place a multi-hop delivery
        // failure leaves evidence on the node that killed it.
        _traceDrop('relay', 'ttlExpired', {
          'packetId': packet.packetId,
          'fromPeer': _peerHexForBleDevice(bleDeviceId),
        });
      } else if (relayAllowed) {
        // ONE decrement per arrival. The hopped copy is what we hold, and it
        // is what a later conveyance sends: storing the packet as received
        // would make the buffered copy a hop richer and it would pay for this
        // same arrival a second time on the way out.
        final hopped = packet.decrementTtl();

        // A transit packet is taken into custody UNCONDITIONALLY: with nothing
        // pushed at other relays, a packet this node did not keep is one it
        // can never offer onward, so it would die here. Custody is the only
        // path onward — the RECIPIENT included. Only a packet's creator may
        // write it unrequested, because at the moment of creation the
        // recipient cannot already hold it; a carrier can never know that,
        // and every carrier linked to the recipient would otherwise write its
        // own copy for the recipient's seen-set to drop. So a carried packet
        // reaches the recipient the way it reaches everyone else — through
        // its sync filter — at the cost of up to one announce interval on
        // the last hop.
        final recipientHex = _recipientHex(packet);
        final carried = recipientHex != null;
        if (carried) {
          _dtnStore.store(recipientHex, hopped);
        }
        if (trace?.active ?? false) {
          // The relay's own view: this node took someone else's sealed packet
          // into custody. Joining these across devices by packetId
          // reconstructs the actual path a message took through the mesh.
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
      case ContentType.syncFilter:
        // Buffer reconciliation runs over BOTH transports, but they answer
        // different question sets — see [SyncTransport]. Over BLE the node
        // answers as a mesh relay, with anything it holds; over UDX it answers
        // only as an endpoint's counterparty, with that peer's own packets.
        // The reply link carries the authenticated peer (trial decrypt proved
        // it), so a conveyance never depends on a transport-level id lookup.
        if (transport == PeerTransport.bleDirect && bleDeviceId != null) {
          _handleSyncFilter(
              frame.chunk, SyncLink.ble(senderPubkey, bleDeviceId));
        } else if (transport == PeerTransport.udp) {
          _handleSyncFilter(frame.chunk,
              SyncLink.udx(senderPubkey, _pubkeyToHex(senderPubkey)));
        }
    }
  }

  /// Reassemble a fragmented neighbour-local packet (ANNOUNCE / handshake).
  /// The payload is a CLEARTEXT [SecureFrame]; [FragmentHandler.accept]
  /// reassembles by its globally-unique messageId (a single-fragment frame
  /// returns immediately). Returns a packet identical to [packet] but with the
  /// reassembled ORIGINAL payload (frame stripped), or null while fragments are
  /// outstanding. A malformed frame is traced and dropped, not crashed.
  GrassrootsPacket? _reassembleNeighbour(GrassrootsPacket packet) {
    final Uint8List? whole;
    try {
      final frame = SecureFrame.decode(packet.payload);
      whole = fragmentHandler.accept(frame);
    } on FormatException catch (e) {
      debugPrint('Dropping malformed neighbour fragment ${packet.type}: $e');
      _traceDrop('neighbourFragment', 'malformed', {
        'packetId': packet.packetId,
        'type': packet.type.name,
      });
      return null;
    }
    if (whole == null) return null;
    // Same packet, reassembled payload. A single-fragment frame is the common
    // case and this rebuild is cheap.
    return packet.copyWith(payload: whole);
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
          // The copy that actually ARRIVED, so the delivery can be joined to
          // the hand-off that produced it — the conveying node's `custody
          // convey` or the relaying node's `relay` record, both keyed by
          // packetId. Without it a delivery named only a messageId and the
          // join had to detour through the sender's `sealed` record, which is
          // on a different device and absent if that device never uploaded.
          // For a fragmented message this is the LAST fragment to land.
          'packetId': packet.packetId,
          'ttl': packet.ttl,
          'relayHops': relayHops,
          // Derived from relayHops, so it is a relabelling and NOT independent
          // evidence: it cannot tell a carried delivery from a flooded one.
          // Use the packetId join above for that.
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

  /// Mark a packet ID as seen (e.g., for outgoing packets). [createdAtMs] is
  /// the packet's own creation stamp — the seen set is windowed by it.
  void markSeen(String packetId, int createdAtMs) {
    _seenPackets.add(packetId, createdAtMs);
  }

  /// Check if a packet ID has been seen before
  bool isDuplicate(String packetId) {
    return _seenPackets.contains(packetId);
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
    _seenPackets.add(sealedPacket.packetId, sealedPacket.createdAtMs);
  }

  /// THE outbound path for every self-originated sealed packet — message, ACK,
  /// read receipt, anything recipient-addressed. The creator seals and hands
  /// the packet here; the ROUTER decides how it travels. There is no
  /// per-content-type delivery path.
  ///
  /// The decision is by CONNECTIVITY, exclusive:
  ///  - Recipient is a directly connected neighbour and the write got in →
  ///    the packet went on the air now and is NOT buffered. Direct delivery
  ///    is not the blind push the no-flood rule forbids: that rule is about
  ///    RELAYED packets, where a holder cannot know what a neighbour already
  ///    has. A just-created packet is one the recipient definitionally lacks.
  ///  - Otherwise (no live leg, BLE down, or the write was refused) → the
  ///    packet enters the DTN buffer and leaves via a future sync exchange —
  ///    store-carry-forward is FOR the recipient that cannot be reached right
  ///    now.
  ///
  /// Either way the packet enters our seen-set, so a copy conveyed back to us
  /// is never re-relayed as a fresh sighting.
  ///
  /// Returns whether the packet went on the air now (false = buffered).
  Future<PeerTransport?> dispatchOutbound(
      Uint8List recipientPubkey, GrassrootsPacket sealedPacket) async {
    final send = directSend;
    final via = send == null ? null : await send(recipientPubkey, sealedPacket);
    if (via != null) {
      _seenPackets.add(sealedPacket.packetId, sealedPacket.createdAtMs);
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'custody',
          't': DateTime.now().millisecondsSinceEpoch,
          'event': 'direct',
          'packetId': sealedPacket.packetId,
          'recipient': _pubkeyToHex(recipientPubkey),
          'via': via == PeerTransport.udp ? 'udp' : 'ble',
        }));
      }
      return via;
    }
    storeInDtnBuffer(recipientPubkey, sealedPacket);
    return null;
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

  /// Every packet currently in custody, across recipients. Test inspection
  /// only — in production the buffer is read exclusively by the sync
  /// offer/request exchange.
  @visibleForTesting
  List<GrassrootsPacket> get dtnBufferedPackets => [
        for (final id in _dtnStore.carriedPacketIds())
          if (_dtnStore.packetById(id) != null) _dtnStore.packetById(id)!,
      ];

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

  /// How far this node's buffer sweep has advanced, in originator-stamped
  /// creation-milliseconds. Each round advertises the oldest held packets at
  /// or after the cursor (up to one filter's worth), then advances the cursor
  /// past them; when it passes the newest held packet it wraps to 0 and
  /// re-sweeps. One global position, not per-peer: consecutive neighbours in
  /// the same announce round get consecutive slices, which spreads coverage
  /// across the fleet rather than sending everyone the same slice.
  int _syncCursorMs = 0;

  /// Most packets one filter response may convey before it stops and lets the
  /// rest ride the next round. A single filter must not be able to pull a
  /// whole buffer in one exchange — that is the airtime the id-list offer
  /// spent and the filter exists to avoid. The remainder is not lost: the
  /// cursor keeps sweeping and the peer re-advertises next announce.
  static const int _maxConveyPerFilter = 64;

  /// Build the GCS filter frame advertising what this node has SEEN — the
  /// compact "do not resend me these" the peer answers by conveying only what
  /// this node has never seen.
  ///
  /// Advertising SEEN, not HELD, is the whole point. A held-filter re-pushes the
  /// backlog to a node that already delivered a message and dropped it from its
  /// buffer — it says "I hold nothing, send me everything" — which measured
  /// 12.76 copies/msg on the air. The seen set (see [SeenPackets]) outlives the
  /// buffer, so an emptied node still says "I have seen these," and the
  /// responder conveys nothing it already handed on.
  ///
  /// This replaces the explicit id-list offer wholesale. There is no decline
  /// state and no open-round bookkeeping: the filter carries what the ASKER has
  /// seen, so a converged pair falls silent by construction — the peer computes
  /// the empty difference and sends nothing. Nothing is inferred from silence,
  /// so the incomplete-round rule the id-list offer needed is gone with it.
  ///
  /// The window `[fromMs, toMs]` is the load-bearing part. A filter that
  /// covers only a slice of the buffer must not provoke the peer to re-send
  /// everything outside that slice, so the peer answers ONLY from packets
  /// whose creation time falls in the window (see [_handleSyncFilter]). The
  /// window's upper bound is the creation stamp of the last packet that fit
  /// the filter, cut on a whole-millisecond boundary by [DtnStore.windowFrom]
  /// so it never splits a group sharing one stamp.
  ///
  /// Returns null when there is nothing to say — but a node holding nothing
  /// still advertises an empty filter over all time, so a neighbour pushes it
  /// the backlog it lacks; that is exactly the fresh/emptied node that
  /// store-carry-forward exists to fill.
  Uint8List? buildSyncFilter(Uint8List peerPubkey) {
    var from = _syncCursorMs;
    var ids = _seenPackets.windowFrom(from, limit: GcsFilter.maxElements);
    if (ids.isEmpty) {
      // Swept past the newest seen packet (or have seen none): wrap and try
      // from the oldest so the sweep is continuous.
      from = 0;
      ids = _seenPackets.windowFrom(0, limit: GcsFilter.maxElements);
    }
    if (ids.isEmpty) {
      // Genuinely seen nothing (a fresh node). Advertise "I have nothing,
      // across all time" so a neighbour sends whatever it carries; its own
      // rate cap bounds the round. Leave the cursor at 0.
      _syncCursorMs = 0;
      return encodeSyncFilter(
          n: 0, fromMs: 0, toMs: _nowMs(), filter: Uint8List(0));
    }
    final toMs = ids.last.createdAtMs;
    final built = GcsFilter.build([for (final e in ids) e.id]);
    // Advance past this slice; wrap when it reaches the end on the next call.
    _syncCursorMs = toMs + 1;
    return encodeSyncFilter(
        n: built.n, fromMs: from, toMs: toMs, filter: built.data);
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// A neighbour advertised what it holds as a GCS filter over a time window.
  /// Send it every packet WE hold in that window whose id the filter proves it
  /// lacks. The window is the neighbour's, not ours: answering outside it
  /// would re-send packets a capped filter simply could not name.
  void _handleSyncFilter(Uint8List payload, SyncLink link) {
    final int n, fromMs, toMs;
    final Uint8List filterData;
    try {
      final f = decodeSyncFilter(payload);
      n = f.n;
      fromMs = f.fromMs;
      toMs = f.toMs;
      filterData = f.filter;
    } on FormatException catch (e) {
      debugPrint('[sync] Malformed filter from ${link.handle}: $e');
      _traceDrop('sync', 'malformedFilter', {'peer': _pubkeyToHex(link.peerPubkey)});
      return;
    }
    final List<int> values;
    try {
      values = GcsFilter.decode(data: filterData, n: n);
    } on FormatException catch (e) {
      debugPrint('[sync] Undecodable filter from ${link.handle}: $e');
      _traceDrop('sync', 'malformedFilter', {'peer': _pubkeyToHex(link.peerPubkey)});
      return;
    }
    final peerHex = _pubkeyToHex(link.peerPubkey);
    final inWindow = _dtnStore.windowBetween(fromMs, toMs);
    final ordered = link.isUdx
        // TARGETED ONLY over UDX: the peer gets what is addressed to IT and
        // nothing else — its own bucket intersected with the window, never
        // third-party transit traffic. The restriction is about volume, not
        // trust. BLE encounters are sporadic and airtime is scarce, so the
        // mesh's open relay is bounded by the medium itself; a UDX link is
        // continuous and fast, and conveying everything over it would push the
        // whole buffer at every connected friend at link speed — turning
        // well-connected nodes into the infrastructure that removing the
        // rendezvous servers deleted. Delivery to the endpoint is the part
        // that carries no such cost, so that is the part UDX gets.
        ? [
            for (final p in inWindow)
              if (_recipientHex(p) == peerHex) p,
          ]
        // Over BLE, direct delivery to the connected peer outranks relay, but
        // relay still happens. Convey packets ADDRESSED TO this peer first, so
        // when [_maxConveyPerFilter] cuts the round short, the peer's own
        // packets (its pending message, an ACK owed to it) are the ones that
        // made it out rather than being starved behind relay backlog for other
        // recipients. The GCS window stays creation-time ordered for cross-node
        // agreement — this only reorders WITHIN the window, and preserves that
        // order inside each group.
        : [
            for (final p in inWindow)
              if (_recipientHex(p) == peerHex) p,
            for (final p in inWindow)
              if (_recipientHex(p) != peerHex) p,
          ];
    var conveyed = 0;
    for (final stored in ordered) {
      if (GcsFilter.mightContain(values, n, stored.packetId)) {
        // The filter says the peer (probably) holds it. A false positive here
        // withholds it for one round and self-heals as the window advances —
        // the bounded cost of the filter's compactness.
        continue;
      }
      // Conveyed AS HELD, exactly as the id-list path did: the buffered packet
      // already paid its one decrement on arrival, and the node receiving it
      // pays the next — so a conveyance is a hop and arrives at the TTL stored
      // here. Nothing unforwardable is in the buffer to convey.
      onSyncSend?.call(stored, link);
      conveyed++;
      if (trace?.active ?? false) {
        unawaited(trace!.log({
          'type': 'custody',
          't': _nowMs(),
          'event': 'convey',
          'packetId': stored.packetId,
          'toDevice': link.handle,
          'via': link.transport.name,
          'toPeer': _pubkeyToHex(link.peerPubkey),
          'ttl': stored.ttl,
        }));
      }
      if (conveyed >= _maxConveyPerFilter) {
        // Stop here; the rest ride the peer's next filter. Recorded so a
        // truncated response is not mistaken for "the peer had everything".
        _traceDrop('sync', 'conveyCapped', {
          'peer': _pubkeyToHex(link.peerPubkey),
          'window': [fromMs, toMs],
        });
        break;
      }
    }
    if (conveyed > 0) {
      debugPrint('[sync] Conveyed $conveyed packet(s) to ${link.handle} '
          'for window [$fromMs, $toMs]');
    }
  }

  // ===== Lifecycle =====

  /// Clean up resources
  void dispose() {
    _seenPackets.clear();
    _deliveredMessages.clear();
    _dtnStore.clear();
  }
}
