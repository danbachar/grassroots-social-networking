import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:redux/redux.dart';
import 'package:flutter/foundation.dart';

import '../store/app_state.dart';
import '../store/peers_actions.dart';
import '../transport/address_utils.dart';
import 'address_table.dart';
import 'signaling_codec.dart';

/// Orchestrates signaling between peers via trusted friend mediators.
///
/// ## Reconnection protocol (the GLP friends-based rendezvous step)
///
/// When agent A's IP changes, A and B reconnect through a mutual
/// well-connected friend S as follows:
/// - A sends RECONNECT(initiatorPubkey=A, peerPubkey=B) to S. S observes A's
///   source address and verifies the initiator matches the sender authenticated
///   by the enclosing Noise session (recovered via trial-decrypt).
/// - S — already connected to B — looks B's current address up in its own
///   friend address table and sends each side a PUNCH_INITIATE carrying the
///   other side's address.
/// - Both sides punch their NATs; the deterministic UDX initiator opens the
///   stream once the path is open.
///
/// A mediator is any client connected to both peers; well-connected friends
/// (globally routable address) are the durable choice and are preferred.
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

  /// Counterpart map for forwarding PUNCH_READY between peers we coordinated.
  final Map<String, Uint8List> _pendingPunchCounterparts = {};

  /// Recently-coordinated punch sessions, keyed by canonical (sorted) pubkey
  /// pair, to drop duplicate matches inside the cooldown window.
  final Map<String, DateTime> _recentPunchCoordinations = {};

  static const _punchCoordinationCooldown = Duration(seconds: 15);

  /// Non-friend pubkey hexes we transiently accept signaling from — the
  /// introducers of an invite we are actively redeeming. A cold-bootstrap
  /// invitee is not (yet) friends with the introducer, so without this its
  /// PUNCH_INITIATE / PUNCH_READY (which drive the invitee's leg of the
  /// punch) would be dropped by the friend gate. Scoped to the redemption
  /// window: the coordinator adds them before sending INTRODUCE and removes
  /// them when the redemption settles.
  final Set<String> _transientTrustedPeers = {};

  /// Transiently accept signaling from [pubkeyHex] (an invite introducer)
  /// for the duration of an in-flight redemption.
  void trustTransientSignalingPeer(String pubkeyHex) {
    _transientTrustedPeers.add(pubkeyHex.toLowerCase());
  }

  /// Stop transiently trusting [pubkeyHex] once its redemption settles.
  void untrustTransientSignalingPeer(String pubkeyHex) {
    _transientTrustedPeers.remove(pubkeyHex.toLowerCase());
  }

  // ===== Callbacks (set by coordinator) =====

  /// Send a signaling payload wrapped in a GrassrootsPacket to a specific peer.
  /// The coordinator wraps the payload in a GrassrootsPacket(type: signaling),
  /// signs it, and sends it via the best available transport.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
  sendSignaling;

  /// Send a signaling payload only over an already-live direct control path.
  /// Used for peer-to-peer punch coordination where falling back to UDP would
  /// re-enter the very path we are trying to establish.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
  sendDirectSignaling;

  /// Fired when a friend mediator (or direct peer) tells us to start
  /// hole-punching. [readyRecipientPubkey] is where we should send PUNCH_READY
  /// after finishing our local punch — either the facilitator or the peer.
  void Function(
    Uint8List peerPubkey,
    String ip,
    int port,
    Uint8List readyRecipientPubkey,
  )?
  onPunchInitiate;

  /// Fired when a hole-punch completes and we should connect to the peer.
  /// (Triggered by PUNCH_READY from the other side via the facilitator.)
  void Function(Uint8List peerPubkey)? onPunchReady;

  /// Fired when a well-connected friend reflects our observed public address
  /// (the GLP spec response to an ANNOUNCE whose claimed address differs from
  /// the observed source). The coordinator updates its public address.
  void Function(Uint8List senderPubkey, String ip, int port)? onAddrReflected;

  /// Fired when an invitee presents an INTRODUCE (a signed invite). The
  /// coordinator owns invite verification (it holds sodium, settings, and the
  /// nonce ledger) and decides the local role: as a named introducer it calls
  /// back into [coordinateIntroduction]; as the inviter it accepts the
  /// invitee and burns the nonce. [observedIp]/[observedPort] are the
  /// invitee's source address on the connection that carried the INTRODUCE.
  void Function(
    Uint8List senderPubkey,
    Uint8List inviteBlob,
    String? observedIp,
    int? observedPort,
  )?
  onIntroduceReceived;

  SignalingService({required this.store, this.codec = const SignalingCodec()}) {
    // Clean up stale address table entries every 60 seconds.
    _staleCleanupTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => addressTable.removeStale(const Duration(minutes: 5)),
    );
  }

  // ===== Outgoing API (called by coordinator) =====

  /// Send RECONNECT(peerPubkey=target) to every trusted mediator — the
  /// well-connected mutual friends that can look up both sides' addresses.
  ///
  /// Called when this agent's connectivity changed (new public IP) and it
  /// wants to reach [targetPubkey].
  ///
  /// Returns the number of mediators the request was sent to.
  Future<int> fanOutReconnect(
    Uint8List targetPubkey, {
    required Uint8List initiatorPubkey,
  }) async {
    return _fanOutCold(
      targetPubkey,
      ReconnectMessage(
        initiatorPubkey: initiatorPubkey,
        peerPubkey: targetPubkey,
      ),
      intent: 'RECONNECT',
    );
  }

  /// Ask one connected friend to mediate reconnection to [targetPubkey].
  Future<bool> requestFriendMediation({
    required Uint8List mediatorPubkey,
    required Uint8List targetPubkey,
    required Uint8List initiatorPubkey,
  }) async {
    final msg = ReconnectMessage(
      initiatorPubkey: initiatorPubkey,
      peerPubkey: targetPubkey,
    );
    return await sendSignaling?.call(mediatorPubkey, codec.encode(msg)) ??
        false;
  }

  /// Proactively mediate two connected friends from the local address table.
  void mediateFriends({
    required Uint8List requesterPubkey,
    required Uint8List targetPubkey,
  }) {
    final requesterHex = _pubkeyToHex(requesterPubkey);
    _handleRendezvous(
      senderPubkey: requesterPubkey,
      senderHex: requesterHex,
      targetPubkey: targetPubkey,
      observedIp: null,
      observedPort: null,
    );
  }

  Future<int> _fanOutCold(
    Uint8List targetPubkey,
    SignalingMessage msg, {
    required String intent,
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final facilitators = _trustedFacilitatorPubkeys(
      targetPubkeyHex: targetHex,
      excludePubkeyHex: targetHex,
    );
    if (facilitators.isEmpty) {
      debugPrint(
        '[$intent] No trusted facilitators to fan out to for ${targetHex.substring(0, 8)}...',
      );
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

  /// Send an INTRODUCE (a signed invite blob) to [recipientPubkey] — an
  /// introducer, then the inviter — as the invitee redeeming an invite.
  Future<bool> sendIntroduce(
    Uint8List recipientPubkey,
    Uint8List inviteBlob,
  ) async {
    final msg = IntroduceMessage(inviteBlob: inviteBlob);
    return await sendSignaling?.call(recipientPubkey, codec.encode(msg)) ??
        false;
  }

  /// Send our current accepted friend set to a friend.
  ///
  /// Recipients maintain this as their friends-of-friends map, which lets
  /// them choose common-friend mediators for friends-based rendezvous.
  Future<bool> sendFriendList(
    Uint8List recipientPubkey,
    List<Uint8List> friendPubkeys,
  ) async {
    final msg = FriendListMessage(friendPubkeys: friendPubkeys);
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

  // ===== Incoming processing (called by MessageRouter via coordinator) =====

  /// Process an incoming signaling packet.
  ///
  /// [senderPubkey] is the authenticated sender from the outer GrassrootsPacket.
  /// [payload] is the raw signaling payload (type byte + message data).
  /// [observedIp] / [observedPort] carry the UDP source address observed by
  /// the transport layer — used when this client acts as a friend mediator.
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
      debugPrint('Failed to decode signaling message: $e');
      return;
    }

    // INTRODUCE is the one message a non-friend may send: it is
    // self-authorizing (the embedded inviter signature is verified by the
    // coordinator), so it bypasses the friend-only trust gate. Everything
    // else stays friend-gated.
    if (msg is IntroduceMessage) {
      onIntroduceReceived?.call(
        senderPubkey,
        msg.inviteBlob,
        observedIp,
        observedPort,
      );
      return;
    }

    if (!_isTrustedSignalingSender(senderHex)) {
      debugPrint(
        'Dropping signaling from untrusted sender '
        '${senderHex.substring(0, 8)}...',
      );
      return;
    }

    switch (msg) {
      case PunchInitiateMessage():
        _handlePunchInitiate(senderPubkey, msg);
      case PunchReadyMessage():
        _handlePunchReady(senderPubkey, msg);
      case AddrReflectMessage():
        _handleAddrReflect(senderPubkey, msg);
      case ReconnectMessage():
        if (!listEquals(msg.initiatorPubkey, senderPubkey)) {
          debugPrint(
            'Dropping RECONNECT from ${senderHex.substring(0, 8)}... — '
            'inner initiator does not match signed sender',
          );
          return;
        }
        _handleRendezvous(
          senderPubkey: senderPubkey,
          senderHex: senderHex,
          targetPubkey: msg.peerPubkey,
          observedIp: observedIp,
          observedPort: observedPort,
        );
      case FriendListMessage():
        _handleFriendList(senderPubkey, msg);
      case IntroduceMessage():
        // Handled above (self-authorizing; bypasses the friend gate).
        break;
    }
  }

  /// Coordinate the invitee↔inviter hole-punch for a verified invite
  /// redemption. Called by the coordinator once it has confirmed (as a named
  /// introducer) that the invite is genuine and both introduce toggles are
  /// open. [inviteeIp]/[inviteePort] are the invitee's observed source
  /// address; the inviter's address comes from this mediator's own table
  /// (the inviter is our friend). Mirrors [_handleRendezvous]'s single-step
  /// punch, but with the invitee identified by the invite rather than by
  /// friendship.
  void coordinateIntroduction({
    required Uint8List inviteePubkey,
    required String inviteeIp,
    required int inviteePort,
    required Uint8List inviterPubkey,
  }) {
    final inviteeHex = _pubkeyToHex(inviteePubkey);
    final inviterHex = _pubkeyToHex(inviterPubkey);
    if (inviteeHex == inviterHex) return;

    final now = DateTime.now();
    _pruneRecentPunchCoordinations(now);
    final sessionKey = _punchSessionKey(inviteeHex, inviterHex);
    final last = _recentPunchCoordinations[sessionKey];
    if (last != null && now.difference(last) < _punchCoordinationCooldown) {
      debugPrint(
        '[introduce] Dropping duplicate introduction '
        '${inviteeHex.substring(0, 8)} ↔ ${inviterHex.substring(0, 8)} — '
        'coordinated ${now.difference(last).inMilliseconds}ms ago',
      );
      return;
    }

    final inviteeFamily = InternetAddress.tryParse(inviteeIp)?.type;
    final inviterAddress = _addressForMediation(
      inviterHex,
      observedIp: null,
      observedPort: null,
      requireFamily: inviteeFamily,
      // The invitee is a bearer-invite stranger — never disclose a
      // private/link-local inviter address to it.
      requireRoutable: true,
    );
    if (inviterAddress == null) {
      debugPrint(
        '[introduce] No routable same-family UDP address for inviter '
        '${inviterHex.substring(0, 8)} — cannot coordinate',
      );
      return;
    }

    _recentPunchCoordinations[sessionKey] = now;
    _pendingPunchCounterparts[inviteeHex] = inviterPubkey;
    _pendingPunchCounterparts[inviterHex] = inviteePubkey;

    debugPrint(
      '[introduce] Coordinating introduction: '
      '${inviteeHex.substring(0, 8)}($inviteeIp:$inviteePort) <-> '
      '${inviterHex.substring(0, 8)}'
      '(${inviterAddress.ip}:${inviterAddress.port})',
    );

    sendSignaling?.call(
      inviterPubkey,
      codec.encode(PunchInitiateMessage(
        peerPubkey: inviteePubkey,
        ip: inviteeIp,
        port: inviteePort,
      )),
    );
    sendSignaling?.call(
      inviteePubkey,
      codec.encode(PunchInitiateMessage(
        peerPubkey: inviterPubkey,
        ip: inviterAddress.ip,
        port: inviterAddress.port,
      )),
    );
  }

  void _handleFriendList(Uint8List senderPubkey, FriendListMessage msg) {
    final friends = <String>{};
    for (final pubkey in msg.friendPubkeys) {
      if (pubkey.length != 32) continue;
      friends.add(_pubkeyToHex(pubkey));
    }
    final senderHex8 = _pubkeyToHex(senderPubkey).substring(0, 8);
    debugPrint(
      '[fof] $senderHex8 advertises ${friends.length} accepted friend(s)',
    );
    store.dispatch(
      PeerFriendListUpdatedAction(
        publicKey: senderPubkey,
        friendPubkeyHexes: friends,
      ),
    );
  }

  /// Handle a RECONNECT friend-mediation request by looking up both friends'
  /// addresses and dispatching PUNCH_INITIATE to both sides.
  ///
  /// A friend mediator follows the GLP friends-based rendezvous step: it must
  /// already be connected to the target friend, and it uses its friend address
  /// table — there is no two-sided matcher and no waiting counterpart.
  void _handleRendezvous({
    required Uint8List senderPubkey,
    required String senderHex,
    required Uint8List targetPubkey,
    required String? observedIp,
    required int? observedPort,
  }) {
    final targetHex = _pubkeyToHex(targetPubkey);

    if (senderHex == targetHex) {
      debugPrint(
        'Dropping RECONNECT from ${senderHex.substring(0, 8)}... — '
        'sender targeting itself',
      );
      return;
    }

    final targetPeer = store.state.peers.getPeerByPubkeyHex(targetHex);
    if (targetPeer == null || !targetPeer.isFriend) {
      debugPrint(
        'Dropping RECONNECT from ${senderHex.substring(0, 8)}... — target '
        '${targetHex.substring(0, 8)} is not a friend of this mediator',
      );
      return;
    }

    final senderAddress = _addressForMediation(
      senderHex,
      observedIp: observedIp,
      observedPort: observedPort,
    );
    if (senderAddress == null) {
      debugPrint(
        'Dropping RECONNECT from ${senderHex.substring(0, 8)}... — no UDP '
        'address available for friends-based mediation',
      );
      return;
    }

    final now = DateTime.now();
    _pruneRecentPunchCoordinations(now);

    final sessionKey = _punchSessionKey(senderHex, targetHex);
    final lastCoordinated = _recentPunchCoordinations[sessionKey];
    if (lastCoordinated != null &&
        now.difference(lastCoordinated) < _punchCoordinationCooldown) {
      debugPrint(
        'Dropping duplicate RECONNECT ${senderHex.substring(0, 8)}'
        ' ↔ ${targetHex.substring(0, 8)} — already coordinated '
        '${now.difference(lastCoordinated).inMilliseconds}ms ago',
      );
      return;
    }

    if (!targetPeer.isReachable) {
      debugPrint(
        'Dropping RECONNECT from ${senderHex.substring(0, 8)}... — target '
        '${targetHex.substring(0, 8)} is not live on this mediator',
      );
      return;
    }

    // Hole punching requires both peers to share an IP address family —
    // a UDP socket bound to IPv4 cannot reach an IPv6 destination, and vice
    // versa. Pick the target's address constrained to the sender's family
    // and bail out if no compatible candidate exists; coordinating a punch
    // across families produces 9 packets sent into the void on each side
    // and a 10s UDX handshake timeout for the user.
    final senderFamily = InternetAddress.tryParse(senderAddress.ip)?.type;
    final targetAddress = _addressForMediation(
      targetHex,
      observedIp: null,
      observedPort: null,
      requireFamily: senderFamily,
    );
    if (targetAddress == null) {
      debugPrint(
        'Dropping RECONNECT from ${senderHex.substring(0, 8)}... — no UDP '
        'address for target ${targetHex.substring(0, 8)} in the same '
        'address family ($senderFamily) as the sender '
        '(${senderAddress.ip})',
      );
      return;
    }

    _recentPunchCoordinations[sessionKey] = now;
    _pendingPunchCounterparts[senderHex] = targetPubkey;
    _pendingPunchCounterparts[targetHex] = senderPubkey;

    debugPrint(
      '[mediate] Coordinating single-step friend mediation: '
      '${senderHex.substring(0, 8)}'
      '(${senderAddress.ip}:${senderAddress.port}) <-> '
      '${targetHex.substring(0, 8)}(${targetAddress.ip}:${targetAddress.port})',
    );

    final initiateToSender = PunchInitiateMessage(
      peerPubkey: targetPubkey,
      ip: targetAddress.ip,
      port: targetAddress.port,
    );
    sendSignaling?.call(senderPubkey, codec.encode(initiateToSender));

    final initiateToTarget = PunchInitiateMessage(
      peerPubkey: senderPubkey,
      ip: senderAddress.ip,
      port: senderAddress.port,
    );
    sendSignaling?.call(targetPubkey, codec.encode(initiateToTarget));
  }

  /// Pick a UDP address suitable for use as a hole-punch target.
  ///
  /// When [requireFamily] is non-null, only candidates whose IP belongs to
  /// that family (IPv4 or IPv6) are considered. The mediator uses this to
  /// pair compatible families across the two punching peers.
  ({String ip, int port})? _addressForMediation(
    String pubkeyHex, {
    required String? observedIp,
    required int? observedPort,
    InternetAddressType? requireFamily,
    bool requireRoutable = false,
  }) {
    bool matchesFamily(String ip) {
      if (requireFamily == null) return true;
      final parsed = InternetAddress.tryParse(ip);
      return parsed != null && parsed.type == requireFamily;
    }

    if (observedIp != null &&
        observedPort != null &&
        matchesFamily(observedIp)) {
      return (ip: observedIp, port: observedPort);
    }

    final registeredAddresses = addressTable.lookupAll(pubkeyHex);
    for (final registered in registeredAddresses) {
      if (!matchesFamily(registered.ip)) continue;
      final normalized = _normalizeMediationAddress(
        registered.ip,
        registered.port,
      );
      if (normalized == null || !isGloballyRoutableAddress(normalized)) {
        continue;
      }
      return (ip: registered.ip, port: registered.port);
    }

    final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);

    for (final candidate in peer?.allUdpAddressCandidates ?? const <String>[]) {
      if (!isGloballyRoutableAddress(candidate)) continue;
      final parsed = parseAddressString(candidate);
      if (parsed == null) continue;
      if (!matchesFamily(parsed.ip.address)) continue;
      return (ip: parsed.ip.address, port: parsed.port);
    }

    // The non-routable fallbacks below can leak a private/link-local address.
    // A caller disclosing the result to a stranger (an invite introduction)
    // passes requireRoutable to suppress them.
    if (requireRoutable) return null;

    for (final registered in registeredAddresses) {
      if (!matchesFamily(registered.ip)) continue;
      final normalized = _normalizeMediationAddress(
        registered.ip,
        registered.port,
      );
      if (normalized != null) {
        return (ip: registered.ip, port: registered.port);
      }
    }

    for (final candidate in peer?.allUdpAddressCandidates ?? const <String>[]) {
      final parsed = parseAddressString(candidate);
      if (parsed == null) continue;
      if (!matchesFamily(parsed.ip.address)) continue;
      return (ip: parsed.ip.address, port: parsed.port);
    }

    return null;
  }

  String? _normalizeMediationAddress(String ip, int port) {
    final parsedIp = InternetAddress.tryParse(ip);
    if (parsedIp == null) return null;
    return AddressInfo(parsedIp, port).toAddressString();
  }

  static String _punchSessionKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

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

  /// Handle PUNCH_INITIATE: a mediator (or direct peer) telling us to start punching.
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
  /// This is the STUN-equivalent for Grassroots. The facilitator saw our real
  /// NAT-translated address on the incoming UDP connection and is reflecting
  /// it back. We update our public address with this value — it has the
  /// correct external port, unlike our local-port-based guess.
  void _handleAddrReflect(Uint8List senderPubkey, AddrReflectMessage msg) {
    // debugPrint('Address reflected by facilitator: ${msg.ip}:${msg.port}');
    onAddrReflected?.call(senderPubkey, msg.ip, msg.port);
  }

  // ===== Lifecycle =====

  void dispose() {
    _staleCleanupTimer?.cancel();
    _staleCleanupTimer = null;
    _pendingPunchCounterparts.clear();
    _recentPunchCoordinations.clear();
    addressTable.clear();
  }

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  bool _isTrustedSignalingSender(String senderHex) {
    if (_transientTrustedPeers.contains(senderHex.toLowerCase())) return true;
    final senderPeer = store.state.peers.getPeerByPubkeyHex(senderHex);
    return senderPeer != null && senderPeer.isFriend;
  }

  /// Trusted mediators in deterministic lexicographic order by pubkey hex:
  /// well-connected friends that are (per the friends-of-friends map) also
  /// friends with the target, so mediating adds no new trust.
  List<Uint8List> _trustedFacilitatorPubkeys({
    required String targetPubkeyHex,
    String? excludePubkeyHex,
  }) {
    final facilitators = <String, Uint8List>{};

    for (final friend in store.state.peers.wellConnectedFriends) {
      final friendHex = _pubkeyToHex(friend.publicKey);
      if (friendHex == excludePubkeyHex) continue;
      if (store.state.peers.friendsOfFriends[friendHex]?.contains(
            targetPubkeyHex,
          ) !=
          true) {
        continue;
      }
      facilitators[friendHex] = friend.publicKey;
    }

    final orderedHexes = facilitators.keys.toList()..sort();
    return [for (final hex in orderedHexes) facilitators[hex]!];
  }
}
