import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart' as libsodium;
import 'package:uuid/uuid.dart';

import '../models/identity.dart';
import '../models/packet.dart';
import '../models/secure_frame.dart';
import '../session/noise_session_manager.dart';

/// DEBUG/TESTBED ONLY. Measures the two constants behind the open question of
/// whether Noise sessions should be capped, on the device that has to live
/// with the answer. Sessions are currently retained without bound.
///
/// The receive path trial-decrypts an inbound sealed packet against the
/// session table until the AEAD tag matches. That gives two numbers:
///
///   * `tFailUs` — one failed AEAD open. A packet NOT addressed to us costs
///     `S × tFailUs`, so this is the marginal price of holding one more
///     session in an uncapped table. It is also the number that decides whether the envelope's
///     recipient field can be removed, because without it every transit packet
///     pays that full walk instead of being rejected on a header compare.
///   * `tHandshakeUs` — the CPU half of one Noise XX exchange. This is what
///     evicting a session would cost when that peer is met again, and it is
///     the other side of any future cap (the BLE round trips are the rest of
///     it and come from field traces, not from here).
///
/// Both are hardware-bound and vary by an order of magnitude across the fleet,
/// so the fleet's weakest phone is the one that decides whether a design is
/// affordable. Measured:
///
///     device                            tFailUs   tHandshakeUs
///     Nexus 5X (2015, A53/A57)            350        84_100
///     arm64 laptop (2024)                  35         4_250
///
/// The per-attempt cost is flat from 32 sessions upward; a much higher reading
/// at 1 session is residual JIT warm-up, not a table-size effect.
class CryptoBench {
  static const _uuid = Uuid();

  /// Session-table sizes to sweep. The per-attempt cost should be flat across
  /// these; a rising curve means something other than the AEAD dominates
  /// (allocation, map iteration) and the linear cost model is wrong.
  static const defaultSessionCounts = [1, 8, 32, 128];

  /// Runs the sweep and returns one result map per session count, plus the
  /// handshake measurement. Safe to call on the main isolate — it is CPU-bound
  /// and takes a few seconds; the caller should keep the UI honest about that.
  static Future<Map<String, dynamic>> run({
    required libsodium.SodiumSumo sodium,
    List<int> sessionCounts = defaultSessionCounts,
    int packets = 100,
  }) async {
    // One global warm-up before any timing. Warming inside each sweep step
    // would scale with that step's session count, and the smallest step would
    // carry JIT cost the largest one does not — which reads as a falling
    // per-attempt cost that is pure artefact.
    await _warmUp(sodium);

    final rows = <Map<String, dynamic>>[];
    for (final s in sessionCounts) {
      rows.add(await _measureDecrypt(
        sodium: sodium,
        sessions: s,
        packets: packets,
      ));
    }
    return {
      'decrypt': rows,
      'handshake': await _measureHandshake(sodium: sodium, rounds: 20),
    };
  }

  /// Builds a hub holding [sessions] live sessions and times two paths against
  /// it: a packet sealed by a stranger (walks all [sessions] and fails) and a
  /// packet from the most-recently-used peer (hits on the first attempt).
  static Future<Map<String, dynamic>> _measureDecrypt({
    required libsodium.SodiumSumo sodium,
    required int sessions,
    required int packets,
  }) async {
    final hubId = await _identity('hub');
    final hub = NoiseSessionManager(identity: hubId, sodium: sodium);

    NoiseSessionManager? mru;
    GrassrootsIdentity? mruId;
    for (var i = 0; i < sessions; i++) {
      final peerId = await _identity('peer$i');
      final peer = NoiseSessionManager(identity: peerId, sodium: sodium);
      await _handshake(
        initiator: peer,
        initPub: peerId.publicKey,
        responder: hub,
        respPub: hubId.publicKey,
      );
      mru = peer;
      mruId = peerId;
    }

    // A peer the hub has no session with: its packets can never open, so every
    // attempt in the table is a failed AEAD.
    final strangerId = await _identity('stranger');
    final stranger = NoiseSessionManager(identity: strangerId, sodium: sodium);
    final strangerHub = NoiseSessionManager(identity: hubId, sodium: sodium);
    await _handshake(
      initiator: stranger,
      initPub: strangerId.publicKey,
      responder: strangerHub,
      respPub: hubId.publicKey,
    );

    Future<GrassrootsPacket> sealFrom(NoiseSessionManager m) => m.encryptPacket(
          _clearPacket(hubId.publicKey),
          remotePubkey: hubId.publicKey,
        );

    // Top up: enough calls that this table's decrypt loop is itself compiled
    // before the clock starts, at every session count.
    final warmCalls = sessions >= 32 ? 20 : (640 ~/ sessions).clamp(20, 200);
    for (var i = 0; i < warmCalls; i++) {
      await hub.trialDecrypt(await sealFrom(stranger));
    }

    final missPackets = <GrassrootsPacket>[];
    for (var i = 0; i < packets; i++) {
      missPackets.add(await sealFrom(stranger));
    }
    final missWatch = Stopwatch()..start();
    for (final p in missPackets) {
      await hub.trialDecrypt(p);
    }
    missWatch.stop();

    // Hit path: MRU-first ordering means the peer we last heard from is tried
    // first, so this is the floor of the receive cost regardless of table size.
    var hitUs = 0.0;
    if (mru != null && mruId != null) {
      final hitPackets = <GrassrootsPacket>[];
      for (var i = 0; i < packets; i++) {
        hitPackets.add(await mru.encryptPacket(
          _clearPacket(hubId.publicKey),
          remotePubkey: hubId.publicKey,
        ));
      }
      final hitWatch = Stopwatch()..start();
      for (final p in hitPackets) {
        await hub.trialDecrypt(p);
      }
      hitWatch.stop();
      hitUs = hitWatch.elapsedMicroseconds / packets;
    }

    final totalAttempts = packets * sessions;
    return {
      'sessions': sessions,
      'packets': packets,
      // The headline: one failed AEAD open.
      'tFailUs': missWatch.elapsedMicroseconds / totalAttempts,
      // What a transit packet costs at this table size.
      'missUs': missWatch.elapsedMicroseconds / packets,
      // What a packet addressed to us costs when the sender is the MRU peer.
      'hitUs': hitUs,
    };
  }

  /// Times the CPU side of a full XX exchange (msg1/msg2/msg3 plus both
  /// splits), which is what an LRU eviction costs on re-encounter — before the
  /// BLE round trips that carry it.
  static Future<Map<String, dynamic>> _measureHandshake({
    required libsodium.SodiumSumo sodium,
    required int rounds,
  }) async {
    final aId = await _identity('hs-a');
    final bId = await _identity('hs-b');

    // Warm-up round, same reason as above.
    await _handshake(
      initiator: NoiseSessionManager(identity: aId, sodium: sodium),
      initPub: aId.publicKey,
      responder: NoiseSessionManager(identity: bId, sodium: sodium),
      respPub: bId.publicKey,
    );

    final watch = Stopwatch()..start();
    for (var i = 0; i < rounds; i++) {
      await _handshake(
        initiator: NoiseSessionManager(identity: aId, sodium: sodium),
        initPub: aId.publicKey,
        responder: NoiseSessionManager(identity: bId, sodium: sodium),
        respPub: bId.publicKey,
      );
    }
    watch.stop();
    return {
      'rounds': rounds,
      'tHandshakeUs': watch.elapsedMicroseconds / rounds,
    };
  }

  /// Drives the decrypt and handshake paths until the JIT has compiled them,
  /// so the sweep measures steady-state cost rather than compilation.
  static Future<void> _warmUp(libsodium.SodiumSumo sodium) async {
    final hubId = await _identity('warm-hub');
    final hub = NoiseSessionManager(identity: hubId, sodium: sodium);
    for (var i = 0; i < 8; i++) {
      final peerId = await _identity('warm-peer\$i');
      await _handshake(
        initiator: NoiseSessionManager(identity: peerId, sodium: sodium),
        initPub: peerId.publicKey,
        responder: hub,
        respPub: hubId.publicKey,
      );
    }
    final strangerId = await _identity('warm-stranger');
    final stranger = NoiseSessionManager(identity: strangerId, sodium: sodium);
    await _handshake(
      initiator: stranger,
      initPub: strangerId.publicKey,
      responder: NoiseSessionManager(identity: hubId, sodium: sodium),
      respPub: hubId.publicKey,
    );
    // ~1600 failed AEAD opens: past the point where further calls get faster.
    for (var i = 0; i < 200; i++) {
      await hub.trialDecrypt(await stranger.encryptPacket(
        _clearPacket(hubId.publicKey),
        remotePubkey: hubId.publicKey,
      ));
    }
  }

  static Future<GrassrootsIdentity> _identity(String nickname) async {
    return GrassrootsIdentity.create(
      keyPair: await Ed25519().newKeyPair(),
      nickname: nickname,
    );
  }

  static GrassrootsPacket _clearPacket(Uint8List recipient) {
    final frame = SecureFrame(
      contentType: ContentType.message,
      messageId: _uuid.v4(),
      chunk: Uint8List(132),
    );
    return GrassrootsPacket(
      type: PacketType.secure,
      ttl: 0,
      recipientPubkey: recipient,
      payload: frame.encode(),
    );
  }

  static Future<void> _handshake({
    required NoiseSessionManager initiator,
    required Uint8List initPub,
    required NoiseSessionManager responder,
    required Uint8List respPub,
  }) async {
    GrassrootsPacket wrap(Uint8List payload) => GrassrootsPacket(
          type: PacketType.noiseHandshake,
          ttl: 0,
          payload: payload,
        );

    final m1 = await initiator.startHandshake(respPub);
    if (m1 == null) throw StateError('handshake already in flight');
    final r1 =
        await responder.handleHandshakePacket(wrap(m1), remotePubkey: initPub);
    final r2 = await initiator.handleHandshakePacket(
      wrap(r1.responsePayload!),
      remotePubkey: respPub,
    );
    await responder.handleHandshakePacket(
      wrap(r2.responsePayload!),
      remotePubkey: initPub,
    );
  }
}
