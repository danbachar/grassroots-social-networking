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
import '../store/settings_state.dart';
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
  /// The BLE mesh. An open-trust node conveys anything it holds, for any
  /// recipient — that relay is what gives the mesh reach beyond direct
  /// neighbours. A closed-trust node conveys only packets addressed to the
  /// peer on the other end, the same as UDX below.
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
  /// lacks. Nothing is ever pushed blindly on connect (see [buildSyncRound]).
  /// Over BLE an open-trust device answers with anything it holds; a
  /// closed-trust device, and every UDX peer, get only packets addressed to
  /// them (see [SyncTransport]).
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

  /// DEBUG/TESTBED. Deliver without acknowledging.
  ///
  /// A throughput measurement wants the radio carrying traffic in ONE
  /// direction. Every acknowledgement is a packet back down the same link, so
  /// leaving them on measures a duplex link and reports it as simplex
  /// capacity.
  ///
  /// Delivery is untouched: the message still arrives and is still handed up.
  /// The sender simply hears nothing, which means it keeps the message in its
  /// buffer until the age cap — harmless for a run, and the reason this is a
  /// testbed switch rather than a mode anything else may use.
  bool suppressAcks = false;

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

  /// A buffered packet left the store WITHOUT an ACK — age expiry, an
  /// eviction, or retirement on its recipient's own seen-filter. The
  /// sender's messageId → packetIds index subscribes to this
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

        // An open-trust device takes a transit packet into custody
        // unconditionally: with nothing pushed at other relays, a packet
        // this node did not keep is one it can never offer onward, so it
        // would die here. Custody is the only path onward — the RECIPIENT
        // included. Only a packet's creator may write it unrequested,
        // because at the moment of creation the recipient cannot already
        // hold it; a carrier can never know that, and every carrier linked
        // to the recipient would otherwise write its own copy for the
        // recipient's seen-set to drop. So a carried packet reaches the
        // recipient the way it reaches everyone else — through its sync
        // filter — at the cost of up to one announce interval on the last
        // hop.
        //
        // A closed-trust device takes no third-party packet into custody at
        // all. Trust there narrows which peers it links with to friends, but
        // a link is not custody: taking custody of someone else's packet
        // exposes it to every peer THAT peer relays to in turn, which may
        // include strangers this device never chose to trust. A closed-trust
        // device only ever carries what it created itself.
        final recipientHex = _recipientHex(packet);
        final relayIsOpen =
            store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.open;
        final carried = recipientHex != null && relayIsOpen;
        if (carried) {
          // Retirable on the recipient's own seen-signal: this is somebody
          // else's packet and we can never observe its end-to-end ACK, so
          // the filter is the only retirement evidence a carrier ever gets.
          _dtnStore.store(recipientHex, hopped, retirableOnSeen: true);
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
      // NOT called `noSession`, which it was until it wasted an evening. That
      // name says "we hold no session with this peer", and a run full of them
      // reads as a mesh whose pairing has collapsed. The measured truth is the
      // opposite: in a 4-phone ring run every one of the 1,200 of these sat
      // alongside a session record showing `attempts: 3, sessions: 3` — the
      // table was full and all three were tried. They are second copies of
      // packets already delivered, which this design produces on purpose,
      // since a direct-written packet stays conveyable over the sync exchange
      // until it is ACKed. `noSession` is still the right word on the SEND
      // side, where it does mean a session is missing; here it never was.
      _traceDrop('decrypt', 'undecryptable', {
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
        // different question sets — see [SyncTransport]. Over BLE an
        // open-trust node answers as a mesh relay, with anything it holds; a
        // closed-trust node, and every UDX peer, answer only as an
        // endpoint's counterparty, with that peer's own packets.
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

    // Testbed ignore list: a phone in the room that is not part of the
    // experiment gets no peer record, and the link its ANNOUNCE arrived on
    // is dropped so it cannot pair or relay.
    if (store.state.settings.ignoredPeerHexes.contains(_pubkeyToHex(pubkey))) {
      _traceDrop('announce', 'ignored', {'peer': _pubkeyToHex(pubkey)});
      if (transport == PeerTransport.bleDirect) {
        onBleAnnounceRejected?.call(pubkey, bleDeviceId);
      }
      return;
    }

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
      if (!suppressAcks) {
        onAckRequested?.call(senderPubkey, messageId, transport);
      }
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
  /// sync-on-connect, conveyed to whoever lacks it, and ends on ACK
  /// ([dropFromDtnBuffer]) or age expiry. Our own undelivered data is never
  /// retired on a recipient's seen-filter — we may be its last holder, so a
  /// false positive there would lose the message outright.
  /// Testbed: bound the DTN buffer, applied immediately.
  void setDtnMaxBytes(int bytes) => _dtnStore.setMaxBytes(bytes);

  void storeInDtnBuffer(
      Uint8List recipientPubkey, GrassrootsPacket sealedPacket,
      {bool retirableOnSeen = false}) {
    _dtnStore.store(_pubkeyToHex(recipientPubkey), sealedPacket,
        retirableOnSeen: retirableOnSeen);
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
  /// A direct write is attempted first when the recipient is a connected
  /// neighbour (BLE leg preferred, else a live UDX connection). But a write
  /// succeeding at the transport level is proof the bytes crossed the air,
  /// not proof the recipient's app layer processed them — a receiver whose
  /// own path-readiness bookkeeping lags can accept the radio transaction
  /// and still drop the payload, with nothing to tell the sender. So the
  /// packet is buffered EITHER WAY. This is not the blind push the no-flood
  /// rule forbids: that rule is about RELAYED packets, where a holder cannot
  /// know what a neighbour already has, while a just-created packet is one
  /// the recipient definitionally lacks — and a peer that already has it
  /// (the direct write really did land) advertises as much in its own
  /// seen-filter, so the buffered copy is never re-offered to them. The
  /// end-to-end ACK ([dropFromDtnBuffer]) retires the entry — this one is our
  /// own data, so the recipient saying it has seen it is not enough; until
  /// then the
  /// sync exchange can still convey a copy over another path, or to a relay,
  /// catching the direct write's apparent success turning out to have been
  /// silent loss on the far end.
  ///
  /// Either way the packet enters our seen-set, so a copy conveyed back to us
  /// is never re-relayed as a fresh sighting.
  ///
  /// Returns the transport the packet went out on now, if any (null = no
  /// live path, buffer-only). A non-null return is NOT "delivered" — the
  /// packet is buffered regardless, pending the ACK.
  Future<PeerTransport?> dispatchOutbound(
      Uint8List recipientPubkey, GrassrootsPacket sealedPacket,
      {bool retirableOnSeen = false}) async {
    // BEFORE the write, not after. "Buffered either way" only holds if the
    // buffering cannot be skipped, and awaiting first makes it skippable: a
    // write that never completes — not refused, not thrown, simply never
    // answered — leaves this function suspended forever, and everything below
    // it, the custody record and the store alike, never runs. The packet is
    // then held nowhere, so store-carry-forward has nothing to redeliver and
    // the message is gone with no drop record to show for it.
    //
    // That is not hypothetical. On 2026-09-01 one central leg stopped
    // answering its ATT writes; the plugin's per-path GATT queue head-of-line
    // blocked behind the unanswered op, and every subsequent message to that
    // ONE peer — 20 of them, over two trials — was sealed and then vanished,
    // while the same device's sends to its other two peers completed normally
    // throughout. Ordering the store first turns that from silent loss into a
    // late delivery by sync exchange.
    storeInDtnBuffer(recipientPubkey, sealedPacket,
        retirableOnSeen: retirableOnSeen);
    final send = directSend;
    final via = send == null ? null : await send(recipientPubkey, sealedPacket);
    if (via != null && (trace?.active ?? false)) {
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

  /// DEBUG/TESTBED ONLY. Empty the DTN memory buffer and the seen-set
  /// (per-step, when a field plan asks) so one step's undelivered backlog
  /// cannot drain into the next step's measurement window.
  ///
  /// The seen-set goes with the buffer because sync filters name it: a round
  /// covers a fixed slice, and a set carried across steps outgrows what a
  /// sweep can cover inside one step — neighbours are then asked about last
  /// step's packets while this step's wait. The delivered-message set is
  /// kept, so a packet still in flight from an earlier step cannot be
  /// delivered twice; it is re-relayed at worst.
  void clearDtnBuffer() {
    _dtnStore.clear();
    _seenPackets.clear();
    _syncCursors.clear();
  }

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

  /// How far the SWEEP has advanced FOR EACH PEER, in originator-stamped
  /// creation-milliseconds, with the time each cursor was last used.
  ///
  /// This is the second of a round's two frames, and it is what keeps the
  /// first one from turning slow delivery into permanent loss. The prefix
  /// frame only ever names the newest [GcsFilter.maxElements] ids, so at the
  /// measured 2 ids/s its floor sits ~9 minutes back, and under clique load
  /// (~100 ids/s) ~11 seconds back. Sync is the ONLY way a buffered packet
  /// reaches any node, so anything permanently below that floor is not
  /// delayed, it is gone — and two partitions that merge after ten minutes is
  /// exactly the case this mesh exists for. The sweep walks forward through
  /// the whole seen-set and wraps, so the ground under the prefix is always
  /// reached again within a bounded number of rounds.
  ///
  /// Per peer, not one position shared across the fleet. A shared cursor
  /// hands consecutive neighbours consecutive slices, so a holder is only
  /// ever asked about the slices that happened to land on it: a node
  /// carrying packets whose ids fall in a window that only ever went to
  /// someone else is never asked and never conveys them. Coverage of the
  /// (peer x slice) space is then accidental, which is what a conveyance
  /// path cannot afford — it showed up as delivery that depended almost
  /// entirely on WHICH peer a packet was addressed to.
  final Map<String, ({int cursorMs, int usedMs})> _syncCursors = {};

  /// The announce cycle every filter built right now belongs to, advanced by
  /// [advanceSyncSalt]. A peer's salt is this plus that peer's own offset —
  /// see [_saltFor].
  int _syncCycle = 0;

  /// The salt a filter for [peerPubkey] is hashed under: the cycle, offset by
  /// something stable about the peer.
  ///
  /// The CYCLE part is what makes one asking occasion one draw. A cycle can
  /// produce several rounds for one peer — a dual-role pair announces on both
  /// legs, and a peer reachable over both transports is asked on each — and
  /// those rounds' prefix frames all cover `[floorMs, nowMs]`, the same
  /// ground. Salting them apart would let the retirement rule score one
  /// occasion as two independent draws and retire a packet inside a single
  /// cycle, the same error as two frames of one round overlapping.
  ///
  /// The PEER part is what keeps different holders independent of each other.
  /// One filter is built per cycle and sent to every neighbour, so with no
  /// offset every holder tests the same id against the same slots and reaches
  /// the SAME verdict: one false positive retires a packet at every carrier
  /// at once, and carrying it in several places stops being redundancy at
  /// all. That is survivable for a message, whose originator holds a copy
  /// this rule may never touch, and not for a confirmation, where every copy
  /// in existence is retirable and nothing regenerates it.
  /// The offset is FNV-1a over the pubkey with a finalizing mix, not a plain
  /// multiply-fold: taken modulo the salt period, a fixed odd multiplier has
  /// an order of 8, so pubkeys that differ by a constant step collapse onto
  /// ONE offset and the independence is lost exactly where it is needed.
  int _saltFor(Uint8List peerPubkey) {
    var h = 0xcbf29ce484222325;
    for (final b in peerPubkey) {
      h ^= b;
      h = (h * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    h ^= h >>> 33;
    h = (h * 0xff51afd7ed558ccd) & 0xFFFFFFFFFFFFFFFF;
    h ^= h >>> 33;
    return (_syncCycle + h) % syncFilterSaltPeriod;
  }

  /// Move to the next cycle's salt. Driven by the announce timer, because the
  /// announce cadence is what an asking occasion IS: a round is built when a
  /// peer's announce arrives, and every round of one cycle asks the same
  /// question of the same ground.
  void advanceSyncSalt() =>
      _syncCycle = (_syncCycle + 1) % syncFilterSaltPeriod;

  /// A cursor is kept only while its peer is someone we still sync with.
  /// Unbounded per-peer state grows with every peer ever met, and the reason
  /// to drop a stale one is not just size: a peer returning after this long
  /// should be swept from the start, which is exactly what a missing cursor
  /// does.
  static const Duration _syncCursorLifetime = Duration(minutes: 10);

  /// Age every sync cursor by [by], so the lifetime rule can be exercised
  /// without a fake clock reaching into the router. Test-only.
  @visibleForTesting
  void debugAgeSyncCursors(Duration by) {
    for (final k in _syncCursors.keys.toList()) {
      final v = _syncCursors[k]!;
      _syncCursors[k] =
          (cursorMs: v.cursorMs, usedMs: v.usedMs - by.inMilliseconds);
    }
  }

  /// Drop cursors whose peers have been silent past [_syncCursorLifetime],
  /// and hand back what is left.
  Map<String, ({int cursorMs, int usedMs})> _liveSyncCursors(int nowMs) {
    _syncCursors.removeWhere(
        (_, v) => nowMs - v.usedMs > _syncCursorLifetime.inMilliseconds);
    return _syncCursors;
  }

  int _cursorFor(String peerHex, int nowMs) =>
      _liveSyncCursors(nowMs)[peerHex]?.cursorMs ?? 0;

  /// Most packets one filter response may convey before it stops and lets the
  /// rest ride the next round. A single filter must not be able to pull a
  /// whole buffer in one exchange — that is the airtime the id-list offer
  /// spent and the filter exists to avoid. The remainder is not lost: the
  /// prefix frame re-anchors at the top every round and the sweep keeps its
  /// place, so what the cap held back is asked for again a cycle later.
  static const int _maxConveyPerFilter = 64;

  /// Ceiling on one round's frames.
  ///
  /// A round is one PREFIX frame — the recent end, re-anchored every round —
  /// and then as many sweep steps as the backlog below it needs, up to this.
  /// It is what the pacer and the airtime budget are written against: every
  /// frame is a separate unacknowledged GATT write on a leg with no queue
  /// behind it, and each one can pull [_maxConveyPerFilter] packets back, so
  /// nothing may hand a peer an unbounded round.
  ///
  /// One step per round was the earlier shape and it could not keep up: a
  /// step names at most one filter-full, so a 2-frame round named at most 212
  /// ids against a backlog whose median was 521 and whose p90 was 1539
  /// (measured 2026-09-02). The ground below the prefix was then covered at
  /// one filter-full per announce interval, which is slower than a loaded
  /// node fills it.
  static const int maxSyncFramesPerRound = 10;

  /// Ids seen at or after the sweep cursor, and the whole seen-set — the two
  /// numbers that say how much of its own history a node still owes a peer.
  /// Traced per round, because without them the sweep's progress can only be
  /// inferred from delivery outcomes.
  ({int pending, int total}) syncCursorState(Uint8List peerPubkey) {
    final now = _nowMs();
    return (
      pending: _seenPackets.countFrom(_cursorFor(_pubkeyToHex(peerPubkey), now)),
      total: _seenPackets.length,
    );
  }

  /// The seen-filter frames for one round with one peer: a PREFIX frame and a
  /// SWEEP frame, in that order.
  ///
  /// Advertising SEEN, not HELD, is the whole point of either. A held-filter
  /// re-pushes the backlog to a node that already delivered a message and
  /// dropped it from its buffer — it says "I hold nothing, send me everything"
  /// — which measured 12.76 copies/msg on the air. The seen set (see
  /// [SeenPackets]) outlives the buffer, so an emptied node still says "I have
  /// seen these," and the responder conveys nothing it already handed on.
  /// There is no decline state and no open-round bookkeeping: a converged pair
  /// falls silent by construction, because the holder computes an empty
  /// difference and sends nothing.
  ///
  /// **The prefix frame** names the newest [GcsFilter.maxElements] seen ids
  /// and closes at NOW. It exists because every bound a node can otherwise
  /// draw comes from its own seen-set, so a window closing at the newest SEEN
  /// stamp caps the ask at this node's own horizon — and a packet created
  /// after that is invisible to it forever, since the only way to lift the cap
  /// is to see the very packet being withheld. The bias is systematic, not
  /// unlucky: the packets still undelivered are preferentially the newest.
  /// Its `fromMs` is 0 when it covers the whole seen-set, and otherwise the
  /// oldest included stamp — a FLOOR, telling the holder that older packets
  /// are outside this filter and not missing, so it must not re-send them.
  ///
  /// **The sweep frame** is the per-peer forward cursor ([_syncCursors]),
  /// unchanged: one filter-full walking through history and wrapping at the
  /// end. It is what makes the prefix's floor a delay rather than a deletion.
  /// At 2 ids/s that floor is under a minute deep and under clique load about
  /// a second, and sync is the ONLY path by which a buffered packet reaches
  /// anyone — so without the sweep, cross-partition mail older than the floor
  /// would never be asked for again by anybody.
  ///
  /// The two are skipped against each other rather than duplicated: when the
  /// prefix already covers the entire seen-set there is nothing left to sweep,
  /// and when the cursor has climbed into the prefix's range the sweep would
  /// re-name ids the prefix just named, so it wraps to the oldest ground
  /// instead — which is the work only it can do.
  ///
  /// Each frame is a whole standalone filter over its own window, so losing
  /// one costs its slice and not the round. A node that has genuinely seen
  /// nothing returns ONE empty filter over all time: the fresh or emptied node
  /// asking for the whole backlog. The list is never empty — a node with
  /// nothing new to say still has to ask, or a quiet node that is MISSING
  /// packets would never be sent them.
  /// [usableBytes] is what one write to this peer can carry — the narrowest
  /// of the pair's ready legs, since a frame may go out on either. Null keeps
  /// the floor-MTU allowance, which is what a transport without a negotiated
  /// MTU (UDX) and a peer with no ready leg both get.
  List<Uint8List> buildSyncRound(Uint8List peerPubkey, {int? usableBytes}) {
    final frames = _buildSyncFrames(peerPubkey, usableBytes);
    // The pacer spreads a round across the announce interval and every frame
    // can pull [_maxConveyPerFilter] packets back, so a round that grew
    // without bound would hand one peer an unbounded ask.
    assert(frames.length <= maxSyncFramesPerRound);
    return frames;
  }

  List<Uint8List> _buildSyncFrames(Uint8List peerPubkey, int? usableBytes) {
    final nowMs = _nowMs();
    final peerHex = _pubkeyToHex(peerPubkey);
    final prior = _liveSyncCursors(nowMs)[peerHex];
    final salt = _saltFor(peerPubkey);
    final frames = <Uint8List>[];
    // What is left for the filter once the sealed packet and the frame's own
    // window header are paid for. Never negative: a leg too narrow to hold
    // even an empty frame gets a filter of no elements, which still asks —
    // an empty filter names nothing and so requests everything in its window.
    final filterBudget = usableBytes == null
        ? GcsFilter.maxPayloadBytes
        : (usableBytes - syncPacketOverhead - syncFilterHeaderSize)
            .clamp(0, GcsFilter.maxPayloadBytes);

    // ---- Frame A: the newest-first prefix, open to NOW above.
    final recent = _seenPackets.newest(GcsFilter.maxElementsFor(filterBudget));
    if (recent.isEmpty) {
      // Genuinely seen nothing (a fresh node). Advertise "I have nothing,
      // across all time" so a neighbour sends whatever it carries. There is no
      // sweep to add: an empty set has no ground to walk.
      _syncCursors[peerHex] = (cursorMs: 0, usedMs: nowMs);
      return [
        encodeSyncFilter(
            n: 0, salt: salt, fromMs: 0, toMs: nowMs, filter: Uint8List(0))
      ];
    }
    // The floor is 0 only when the prefix IS the whole seen-set: then nothing
    // was left below it that a holder has to be told to withhold.
    // [SeenPackets.newest] has already cut the prefix back to a whole
    // millisecond at its oldest end, so the floor never splits a stamp group.
    final coversAll = recent.length == _seenPackets.length;
    final floorMs = coversAll ? 0 : recent.first.createdAtMs;

    final prefix = GcsFilter.build([for (final e in recent) e.id],
        salt: salt, maxPayloadBytes: filterBudget);
    frames.add(encodeSyncFilter(
        n: prefix.n,
        salt: salt,
        fromMs: floorMs,
        toMs: nowMs,
        filter: prefix.data));
    if (coversAll) {
      // One frame said everything this node knows. A sweep frame would name
      // the same ids over the same ground — pure airtime.
      _syncCursors[peerHex] = (cursorMs: 0, usedMs: nowMs);
      return frames;
    }

    // ---- Frames B..N: the per-peer forward sweep, walking history.
    //
    // The prefix above holds the recent end; everything below its floor is
    // what the sweep has to catch up on, and one step covers at most one
    // filter-full of it. Spending the rest of the round's frame budget on
    // consecutive steps covers that ground in one round instead of one step
    // per announce interval.
    //
    // Each step starts past the previous step's newest stamp, so no two
    // frames of a round describe the same ground. The loop stops early when
    // the sweep reaches the prefix floor — above it the prefix already
    // speaks — or when the buffer runs out.
    var cursor = prior?.cursorMs ?? 0;
    while (frames.length < maxSyncFramesPerRound) {
      if (cursor >= floorMs) {
        // The cursor has climbed into the prefix's range, so anything it
        // named here the prefix just named. Wrap to the oldest ground, which
        // is the half of the round only the sweep covers — but only on the
        // round's FIRST step: wrapping mid-round would re-walk ground this
        // same round already described.
        if (frames.length > 1) break;
        cursor = 0;
      }
      var ids = _seenPackets.windowFrom(cursor,
          limit: GcsFilter.maxElementsFor(filterBudget));
      if (ids.isEmpty) {
        // Swept past the newest seen packet: wrap so the sweep is continuous.
        if (frames.length > 1) break;
        cursor = 0;
        ids = _seenPackets.windowFrom(cursor,
            limit: GcsFilter.maxElementsFor(filterBudget));
      }
      // Cut at the prefix's floor. `windowFrom` bounds a window BELOW and by
      // count, never above, so a step starting just under the floor takes its
      // whole count and runs past it into ground the prefix already
      // describes. That costs twice: the holder answers the band from both
      // frames, conveying anything the asker lacks two times over, and the
      // two frames share the round's salt AND its element count, so one
      // packet's hash target is identical in both and a false positive in the
      // prefix repeats in the sweep rather than being redrawn. Two votes in
      // one round out of what is a single draw is exactly what the retirement
      // rule prices at two.
      //
      // [SeenPackets.newest] cuts its selection back to a whole stamp group,
      // so the floor splits no group — except when its whole selection is one
      // stamp, where there is nothing to cut back to. A stamp holding more
      // ids than a filter can name cannot be described by these frames at
      // all: the windows are whole milliseconds, so any window holding part
      // of that group holds all of it. The unnamed remainder reads as absent
      // and is conveyed again each round, which costs airtime and never
      // delivery — the receiver has them and drops the copies.
      ids = [
        for (final e in ids)
          if (e.createdAtMs < floorMs) e,
      ];
      if (ids.isEmpty) {
        // Caught the prefix up: nothing is left between here and the floor.
        // Restart at the oldest ground, which is the half of history only the
        // sweep covers. Parking on the floor instead does NOT come back round
        // — the floor rises with every new id, so the cursor would sit just
        // under it and re-describe the one band that had just dropped out of
        // the prefix, round after round, while deep history was never asked
        // for again.
        cursor = 0;
        break;
      }
      // Closed at the last stamp it NAMES, never at `now`: a frame asserts
      // "over [fromMs, toMs] this filter names everything I have," so
      // widening the top past the ids it actually lists asserts absence over
      // ground it never described, and the holder conveys packets we
      // demonstrably hold. That is the prefix frame's job, and it earns the
      // open top by being anchored at the newest end in the first place.
      final sweepTo = ids.last.createdAtMs;
      final sweep = GcsFilter.build([for (final e in ids) e.id],
          salt: salt, maxPayloadBytes: filterBudget);
      frames.add(encodeSyncFilter(
          n: sweep.n,
          salt: salt,
          fromMs: cursor,
          toMs: sweepTo,
          filter: sweep.data));
      cursor = sweepTo + 1;
      if (cursor >= floorMs) {
        cursor = 0;
        break;
      }
    }
    // The cursor resumes where this round's last step stopped — for THIS peer.
    _syncCursors[peerHex] = (cursorMs: cursor, usedMs: nowMs);
    return frames;
  }

  int _nowMs() => DateTime.now().millisecondsSinceEpoch;

  /// A neighbour advertised what it has SEEN as a GCS filter over a time
  /// window. Send it every packet WE hold in that window whose id the filter
  /// proves it lacks. The window is the neighbour's, not ours: answering
  /// outside it would re-send packets a capped filter simply could not name.
  void _handleSyncFilter(Uint8List payload, SyncLink link) {
    final int n, salt, fromMs, toMs;
    final Uint8List filterData;
    try {
      final f = decodeSyncFilter(payload);
      n = f.n;
      salt = f.salt;
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
    // Relay only happens over BLE, and only for an open-trust device. An
    // open-trust device's custody-take is unconditional (see processPacket),
    // so this check is what actually decides whether its held third-party
    // packets go out. For a closed-trust device this is defense in depth,
    // not the primary guard: custody-take already refused every third-party
    // packet at the door, so a closed-trust buffer holds nothing but its own
    // packets to answer with regardless of this check.
    final meshRelayAllowed = !link.isUdx &&
        store.state.settings.coldCallTrustLevel == ColdCallTrustLevel.open;
    final ordered = meshRelayAllowed
        // Over BLE with open trust, direct delivery to the connected peer
        // outranks relay, but relay still happens. Convey packets ADDRESSED
        // TO this peer first, so when [_maxConveyPerFilter] cuts the round
        // short, the peer's own packets (its pending message, an ACK owed to
        // it) are the ones that made it out rather than being starved behind
        // relay backlog for other recipients. The GCS window stays
        // creation-time ordered for cross-node agreement — this only
        // reorders WITHIN the window, and preserves that order inside each
        // group.
        ? [
            for (final p in inWindow)
              if (_recipientHex(p) == peerHex) p,
            for (final p in inWindow)
              if (_recipientHex(p) != peerHex) p,
          ]
        // TARGETED ONLY: the peer gets what is addressed to IT and nothing
        // else — its own bucket intersected with the window, never
        // third-party transit traffic. Over UDX this is about volume: a UDX
        // link is continuous and fast, and conveying everything over it
        // would push the whole buffer at every connected friend at link
        // speed — turning well-connected nodes into the infrastructure that
        // removing the rendezvous servers deleted. Over BLE under closed
        // trust it is about exposure instead: relaying a third party's
        // packet hands it to every peer that party relays to in turn, and a
        // closed-trust device does not extend that risk to traffic that is
        // not its own.
        : [
            for (final p in inWindow)
              if (_recipientHex(p) == peerHex) p,
          ];
    var conveyed = 0;
    // Counted only when tracing: `packetsFor` walks the asker's bucket, which
    // is cheap but pointless on a production round.
    final tracing = trace?.active ?? false;
    final ownForPeer =
        tracing ? _dtnStore.packetsFor(peerHex) : const <GrassrootsPacket>[];
    final ownHeld = ownForPeer.length;
    // Mail for this asker that sits BELOW the floor this frame declared. The
    // prefix frame's floor is under a minute deep at 2 ids/s and about a
    // second under clique load, and sync is the only path a buffered packet
    // has — so
    // this counts exactly what the forward sweep frame is keeping alive. A run
    // where it is flat zero is a run where the sweep could be dropped; a run
    // where it is not is a run where dropping it would have LOST that mail,
    // not delayed it.
    final ownBelowFloor = [
      for (final p in ownForPeer)
        if (p.createdAtMs < fromMs) p,
    ].length;
    final ownInWindow = tracing
        ? [for (final p in inWindow) if (_recipientHex(p) == peerHex) p].length
        : 0;
    var ownConveyed = 0;
    for (final stored in ordered) {
      if (GcsFilter.mightContain(values, n, stored.packetId, salt: salt)) {
        // The filter says the peer (probably) holds it. A false positive here
        // withholds it for one round and self-heals on the next: the peer's
        // rounds are salted, so the collision is redrawn rather than repeated
        // — the bounded cost of the filter's compactness.
        continue;
      }
      // Conveyed AS HELD, exactly as the id-list path did: the buffered packet
      // already paid its one decrement on arrival, and the node receiving it
      // pays the next — so a conveyance is a hop and arrives at the TTL stored
      // here. Nothing unforwardable is in the buffer to convey.
      onSyncSend?.call(stored, link);
      conveyed++;
      if (_recipientHex(stored) == peerHex) ownConveyed++;
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
    if (trace?.active ?? false) {
      // The HOLDER's side of the round, which nothing recorded before. The
      // asker's record says how much of itself it managed to describe; this
      // says what that description was worth — how much of what we hold the
      // window even reached (`inWindow` against `held`), and how much of that
      // the filter then claimed. Without the pair, a buffer that sits full and
      // motionless is unattributable: "the window never covered it" and "the
      // peer said it already had it" look identical from outside, and they
      // have opposite fixes.
      unawaited(trace!.log({
        'type': 'sync',
        'event': 'answer',
        't': _nowMs(),
        'peer': peerHex,
        'transport': link.transport.name,
        'window': [fromMs, toMs],
        // The round this frame belongs to, so a reduction can tell a peer's
        // successive rounds apart and check that the draws really did change.
        'salt': salt,
        'held': _dtnStore.totalCount,
        'inWindow': inWindow.length,
        'conveyed': conveyed,
        'withheld': inWindow.length - conveyed,
        // The pooled counts above cannot answer the question they were added
        // for. A holder's buffer is mostly OTHER people's mail plus its own
        // already-delivered copies waiting on an ACK, and withholding those is
        // correct behaviour — so a high `withheld` reads as a fault when it is
        // usually the system working. What matters is the asker's OWN
        // undelivered mail, and there the two failures finally separate:
        //   ownHeld     - addressed to this asker, in our buffer right now
        //   ownInWindow - ...and the window actually reached it
        //   ownWithheld - ...and the filter then claimed it
        // `ownHeld > 0` with `ownInWindow == 0` is the window never reaching
        // the packet. `ownWithheld > 0` is the asker claiming to hold mail it
        // never delivered. Measured on 2026-09-02 one relay held 21 packets
        // for a neighbour it had a live link to and conveyed none of them, and
        // the pooled numbers could not say which of those two it was.
        //   ownBelowFloor - ...and sits under this frame's fromMs entirely,
        //                   so only the sweep frame can ever reach it
        'ownHeld': ownHeld,
        'ownInWindow': ownInWindow,
        'ownConveyed': ownConveyed,
        'ownWithheld': ownInWindow - ownConveyed,
        'ownBelowFloor': ownBelowFloor,
      }));
    }

    // The peer has just told us what it has SEEN. Anything we are holding
    // FOR IT that it already has is finished: its journey is over and no
    // other signal will ever say so, since a carrier cannot observe an
    // end-to-end ACK and nothing acknowledges a confirmation. Retiring it
    // here is the only retirement those two populations get short of age.
    // Scoped by the store to entries that are safe to lose on a filter false
    // positive — see `_Entry.retirableOnSeen`.
    // The SALT is what a second vote has to differ in. A changed id set is
    // not enough on its own: under one salt a packet's hash target is fixed,
    // so two frames that share a salt put the same value against two heavily
    // overlapping sets of occupied slots and agree with each other far more
    // often than two draws would.
    final retired = _dtnStore.retireSeenFor(
        peerHex, (id) => GcsFilter.mightContain(values, n, id, salt: salt),
        fromMs: fromMs, toMs: toMs, voteSalt: salt);
    if (retired > 0 && (trace?.active ?? false)) {
      unawaited(trace!.log({
        'type': 'custody',
        't': _nowMs(),
        'event': 'retiredSeen',
        'count': retired,
        'toPeer': peerHex,
        'held': _dtnStore.totalCount,
        'heldBytes': _dtnStore.totalBytes,
      }));
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
