import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:sodium_libs/sodium_libs_sumo.dart' as libsodium;

import '../models/identity.dart';
import '../models/packet.dart';

const _noiseProtocolName = 'Noise_XX_25519_ChaChaPoly_SHA256';
const _handshakePayloadVersion = 1;
const _applicationPayloadVersion = 1;
const _aeadMacLength = 16;

enum NoiseHandshakeRole { initiator, responder }

enum _NoiseHandshakeMessage {
  message1(1),
  message2(2),
  message3(3);

  final int value;
  const _NoiseHandshakeMessage(this.value);

  static _NoiseHandshakeMessage fromValue(int value) {
    return _NoiseHandshakeMessage.values.firstWhere(
      (message) => message.value == value,
      orElse: () => throw FormatException('Unknown Noise message: $value'),
    );
  }
}

class NoiseHandshakeResult {
  final Uint8List? responsePayload;
  final bool sessionEstablished;

  const NoiseHandshakeResult({
    this.responsePayload,
    this.sessionEstablished = false,
  });
}

/// Owns Noise XX session state, keyed by peer identity.
///
/// The Noise static key is the X25519 form of the local Ed25519 transport
/// identity, derived via the standard birational map (libsodium
/// `crypto_sign_ed25519_*_to_curve25519`). Because the public half is a public
/// function of the Ed25519 public key, each peer recomputes the expected static
/// from the counterpart's known identity and verifies the Noise-delivered static
/// against it, aborting on mismatch (see [_verifyRemoteStatic]) — the key check
/// in `docs/GLP_Networking_API/sections/ip.tex` §IP Connection. Handshake
/// authenticity rests solely on the Noise transcript plus this static-key
/// check; the sender-anonymous mesh envelope carries no per-packet signature.
class NoiseSessionManager {
  final GrassrootsIdentity identity;

  /// libsodium handle providing the Ed25519↔X25519 conversion used to derive
  /// and verify Noise static keys.
  final libsodium.SodiumSumo sodium;

  final Duration handshakeTimeout;

  /// Active sessions / in-flight handshakes, keyed by the peer's Ed25519 public
  /// key (hex). A mesh session is end-to-end and path-independent, so it is NOT
  /// keyed by transport — the same session serves direct and relayed paths.
  final Map<String, _SessionEntry> _entries = {};

  Future<SimpleKeyPair>? _staticKeyPairFuture;

  NoiseSessionManager({
    required this.identity,
    required this.sodium,
    this.handshakeTimeout = const Duration(seconds: 5),
  });

  bool hasSession(Uint8List remotePubkey) {
    return _entries[_hex(remotePubkey)]?.session != null;
  }

  /// Starts an XX initiator handshake if no session or in-flight handshake
  /// exists. Returns the encoded first handshake payload to send, or null if
  /// the caller should simply wait for the existing handshake.
  Future<Uint8List?> startHandshake(Uint8List remotePubkey) async {
    final hex = _hex(remotePubkey);
    final entry = _entries.putIfAbsent(hex, _SessionEntry.new);
    if (entry.session != null || entry.handshake != null) {
      return null;
    }
    entry.remotePubkey = Uint8List.fromList(remotePubkey);

    final handshake = await _NoiseHandshakeState.create(
      role: NoiseHandshakeRole.initiator,
      localStaticKeyPair: await _staticKeyPair(),
    );
    final body = await handshake.writeMessage1();
    entry
      ..session = null
      ..handshake = handshake
      ..completer = Completer<bool>();
    return _encodeHandshakePayload(_NoiseHandshakeMessage.message1, body);
  }

  Future<bool> waitForSession(Uint8List remotePubkey) async {
    final entry = _entries[_hex(remotePubkey)];
    if (entry?.session != null) return true;

    final completer = entry?.completer;
    if (completer == null) return false;

    try {
      return await completer.future.timeout(
        handshakeTimeout,
        onTimeout: () {
          reset(remotePubkey);
          return false;
        },
      );
    } catch (_) {
      return false;
    }
  }

  /// Handle an inbound Noise handshake packet. [remotePubkey] is the peer's
  /// Ed25519 identity, resolved by the coordinator from the inbound BLE path
  /// (the peer's verified self-signed ANNOUNCE) — NOT from the packet, which no
  /// longer carries a sender. Handshakes are neighbor-local (not flooded).
  Future<NoiseHandshakeResult> handleHandshakePacket(
    GrassrootsPacket packet, {
    required Uint8List remotePubkey,
  }) async {
    final (message, body) = _decodeHandshakePayload(packet.payload);
    final hex = _hex(remotePubkey);
    final entry = _entries.putIfAbsent(hex, _SessionEntry.new);
    entry.remotePubkey = Uint8List.fromList(remotePubkey);

    switch (message) {
      case _NoiseHandshakeMessage.message1:
        return _handleMessage1(entry, hex, body);
      case _NoiseHandshakeMessage.message2:
        return _handleMessage2(entry, hex, remotePubkey, body);
      case _NoiseHandshakeMessage.message3:
        return _handleMessage3(entry, hex, remotePubkey, body);
    }
  }

  Future<GrassrootsPacket> encryptPacket(
    GrassrootsPacket packet, {
    required Uint8List remotePubkey,
  }) async {
    if (packet.type != PacketType.secure) return packet;

    final session = _entries[_hex(remotePubkey)]?.session;
    if (session == null) {
      throw StateError('No Noise session for ${_hex(remotePubkey)}');
    }

    final encryptedPayload =
        await session.encryptPayload(packet, identity.publicKey);
    // The wire type stays `secure`; only the payload becomes ciphertext.
    return packet.copyWith(payload: encryptedPayload);
  }

  /// Decrypt a sender-anonymous [PacketType.secure] packet by trial-decrypting
  /// against every active session — the AEAD tag identifies the right one (the
  /// outer envelope has no sender to look it up by). Returns the cleartext
  /// packet (still typed `secure`; the caller decodes its [SecureFrame]) plus
  /// the recovered sender pubkey, or null if no session opens it.
  Future<(GrassrootsPacket, Uint8List)?> trialDecrypt(
    GrassrootsPacket packet,
  ) async {
    if (packet.type != PacketType.secure) return null;

    for (final entry in _entries.values) {
      final session = entry.session;
      final peer = entry.remotePubkey;
      if (session == null || peer == null) continue;
      try {
        final clearPayload = await session.decryptPayload(packet, peer);
        return (packet.copyWith(payload: clearPayload), peer);
      } catch (_) {
        // Wrong session (AEAD tag mismatch) or replay — try the next.
        continue;
      }
    }
    return null;
  }

  void reset(Uint8List remotePubkey) {
    final removed = _entries.remove(_hex(remotePubkey));
    removed?.complete(false);
  }

  void dispose() {
    for (final entry in _entries.values) {
      entry.complete(false);
    }
    _entries.clear();
  }

  Future<NoiseHandshakeResult> _handleMessage1(
    _SessionEntry entry,
    String remoteHex,
    Uint8List body,
  ) async {
    final existingHandshake = entry.handshake;
    if (existingHandshake?.role == NoiseHandshakeRole.initiator) {
      final localHex = _hex(identity.publicKey);
      if (localHex.compareTo(remoteHex) < 0) {
        return const NoiseHandshakeResult();
      }
      entry.complete(false);
    }

    final handshake = await _NoiseHandshakeState.create(
      role: NoiseHandshakeRole.responder,
      localStaticKeyPair: await _staticKeyPair(),
    );
    await handshake.readMessage1(body);
    final responseBody = await handshake.writeMessage2();
    entry
      ..session = null
      ..handshake = handshake
      ..completer = Completer<bool>();
    return NoiseHandshakeResult(
      responsePayload: _encodeHandshakePayload(
        _NoiseHandshakeMessage.message2,
        responseBody,
      ),
    );
  }

  Future<NoiseHandshakeResult> _handleMessage2(
    _SessionEntry entry,
    String remoteHex,
    Uint8List remotePubkey,
    Uint8List body,
  ) async {
    final handshake = entry.handshake;
    if (handshake == null ||
        handshake.role != NoiseHandshakeRole.initiator ||
        entry.session != null) {
      return const NoiseHandshakeResult();
    }

    await handshake.readMessage2(body);
    if (!_verifyRemoteStatic(handshake, remotePubkey)) {
      _entries.remove(remoteHex);
      entry.complete(false);
      return const NoiseHandshakeResult();
    }
    final responseBody = await handshake.writeMessage3();
    final session = await handshake.splitForInitiator();
    entry
      ..session = session
      ..handshake = null;
    entry.complete(true);
    return NoiseHandshakeResult(
      responsePayload: _encodeHandshakePayload(
        _NoiseHandshakeMessage.message3,
        responseBody,
      ),
      sessionEstablished: true,
    );
  }

  Future<NoiseHandshakeResult> _handleMessage3(
    _SessionEntry entry,
    String remoteHex,
    Uint8List remotePubkey,
    Uint8List body,
  ) async {
    final handshake = entry.handshake;
    if (handshake == null ||
        handshake.role != NoiseHandshakeRole.responder ||
        entry.session != null) {
      return const NoiseHandshakeResult();
    }

    await handshake.readMessage3(body);
    if (!_verifyRemoteStatic(handshake, remotePubkey)) {
      _entries.remove(remoteHex);
      entry.complete(false);
      return const NoiseHandshakeResult();
    }
    final session = await handshake.splitForResponder();
    entry
      ..session = session
      ..handshake = null;
    entry.complete(true);
    return const NoiseHandshakeResult(sessionEstablished: true);
  }

  Future<SimpleKeyPair> _staticKeyPair() {
    return _staticKeyPairFuture ??= () async {
      // Derive the Noise static key from the Ed25519 identity via the standard
      // birational map, so its public half is recomputable from the identity's
      // public key by any peer (see [_verifyRemoteStatic]).
      final edSecret = libsodium.SecureKey.fromList(sodium, identity.privateKey);
      try {
        final curveSecret = sodium.crypto.sign.skToCurve25519(edSecret);
        try {
          return SimpleKeyPairData(
            curveSecret.extractBytes(),
            publicKey: SimplePublicKey(
              sodium.crypto.sign.pkToCurve25519(identity.publicKey),
              type: KeyPairType.x25519,
            ),
            type: KeyPairType.x25519,
          );
        } finally {
          curveSecret.dispose();
        }
      } finally {
        edSecret.dispose();
      }
    }();
  }

  /// Verify the Noise-delivered remote static key equals the X25519 form of the
  /// claimed sender's Ed25519 identity ([remotePubkey]). A mismatch — a peer
  /// presenting a static that does not belong to the identity it claims, or a
  /// tampered handshake — aborts the handshake. Implements the key check in
  /// `docs/GLP_Networking_API/sections/ip.tex` §IP Connection.
  bool _verifyRemoteStatic(
    _NoiseHandshakeState handshake,
    Uint8List remotePubkey,
  ) {
    final delivered = handshake.remoteStaticPublicKey;
    if (delivered == null) return false;
    final Uint8List expected;
    try {
      expected = sodium.crypto.sign.pkToCurve25519(remotePubkey);
    } catch (_) {
      // Not a valid Ed25519 point — cannot be an honest peer's key.
      return false;
    }
    return _bytesEqual(delivered.bytes, expected);
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class _SessionEntry {
  _NoiseTransportSession? session;
  _NoiseHandshakeState? handshake;
  Completer<bool>? completer;

  /// The peer's Ed25519 public key (set once known). Used as the AAD sender
  /// when trial-decrypting an inbound sealed packet against this session.
  Uint8List? remotePubkey;

  void complete(bool value) {
    final pending = completer;
    if (pending != null && !pending.isCompleted) {
      pending.complete(value);
    }
    completer = null;
  }
}

class _NoiseHandshakeState {
  final NoiseHandshakeRole role;
  final SimpleKeyPair localStaticKeyPair;
  final _NoiseSymmetricState symmetric;
  final X25519 _x25519 = X25519();

  SimpleKeyPair? _localEphemeralKeyPair;
  SimplePublicKey? _remoteEphemeralPublicKey;
  SimplePublicKey? _remoteStaticPublicKey;
  _NoiseTransportSession? _initiatorSession;
  _NoiseTransportSession? _responderSession;

  /// The remote peer's static public key as delivered in the XX handshake
  /// (messages 2/3). Verified against the expected identity by
  /// [NoiseSessionManager._verifyRemoteStatic].
  SimplePublicKey? get remoteStaticPublicKey => _remoteStaticPublicKey;

  _NoiseHandshakeState._({
    required this.role,
    required this.localStaticKeyPair,
    required this.symmetric,
  });

  static Future<_NoiseHandshakeState> create({
    required NoiseHandshakeRole role,
    required SimpleKeyPair localStaticKeyPair,
  }) async {
    final symmetric = await _NoiseSymmetricState.initialize();
    return _NoiseHandshakeState._(
      role: role,
      localStaticKeyPair: localStaticKeyPair,
      symmetric: symmetric,
    );
  }

  Future<Uint8List> writeMessage1() async {
    _localEphemeralKeyPair = await _x25519.newKeyPair();
    final ephemeral = await _localEphemeralKeyPair!.extractPublicKey();
    await symmetric.mixHash(ephemeral.bytes);
    return Uint8List.fromList(ephemeral.bytes);
  }

  Future<void> readMessage1(Uint8List body) async {
    if (body.length != 32) {
      throw const FormatException('Noise message 1 must be 32 bytes');
    }
    _remoteEphemeralPublicKey = SimplePublicKey(
      Uint8List.fromList(body),
      type: KeyPairType.x25519,
    );
    await symmetric.mixHash(body);
  }

  Future<Uint8List> writeMessage2() async {
    final remoteEphemeral = _requireRemoteEphemeral();
    _localEphemeralKeyPair = await _x25519.newKeyPair();
    final ephemeral = await _localEphemeralKeyPair!.extractPublicKey();
    await symmetric.mixHash(ephemeral.bytes);
    await symmetric.mixKey(await _dh(_localEphemeralKeyPair!, remoteEphemeral));

    final staticPublic = await localStaticKeyPair.extractPublicKey();
    final encryptedStatic = await symmetric.encryptAndHash(staticPublic.bytes);
    await symmetric.mixKey(await _dh(localStaticKeyPair, remoteEphemeral));

    return Uint8List.fromList([...ephemeral.bytes, ...encryptedStatic]);
  }

  Future<void> readMessage2(Uint8List body) async {
    if (body.length != 32 + 48) {
      throw const FormatException('Noise message 2 must be 80 bytes');
    }
    final localEphemeral = _requireLocalEphemeral();
    final remoteEphemeralBytes = body.sublist(0, 32);
    _remoteEphemeralPublicKey = SimplePublicKey(
      Uint8List.fromList(remoteEphemeralBytes),
      type: KeyPairType.x25519,
    );
    await symmetric.mixHash(remoteEphemeralBytes);
    await symmetric.mixKey(
      await _dh(localEphemeral, _remoteEphemeralPublicKey!),
    );

    final remoteStaticBytes = await symmetric.decryptAndHash(body.sublist(32));
    _remoteStaticPublicKey = SimplePublicKey(
      Uint8List.fromList(remoteStaticBytes),
      type: KeyPairType.x25519,
    );
    await symmetric.mixKey(await _dh(localEphemeral, _remoteStaticPublicKey!));
  }

  Future<Uint8List> writeMessage3() async {
    final remoteEphemeral = _requireRemoteEphemeral();
    final staticPublic = await localStaticKeyPair.extractPublicKey();
    final encryptedStatic = await symmetric.encryptAndHash(staticPublic.bytes);
    await symmetric.mixKey(await _dh(localStaticKeyPair, remoteEphemeral));
    return Uint8List.fromList(encryptedStatic);
  }

  Future<void> readMessage3(Uint8List body) async {
    if (body.length != 48) {
      throw const FormatException('Noise message 3 must be 48 bytes');
    }
    final localEphemeral = _requireLocalEphemeral();
    final remoteStaticBytes = await symmetric.decryptAndHash(body);
    _remoteStaticPublicKey = SimplePublicKey(
      Uint8List.fromList(remoteStaticBytes),
      type: KeyPairType.x25519,
    );
    await symmetric.mixKey(await _dh(localEphemeral, _remoteStaticPublicKey!));
  }

  Future<_NoiseTransportSession> splitForInitiator() async {
    return _initiatorSession ??= await symmetric.split(initiator: true);
  }

  Future<_NoiseTransportSession> splitForResponder() async {
    return _responderSession ??= await symmetric.split(initiator: false);
  }

  SimpleKeyPair _requireLocalEphemeral() {
    final keyPair = _localEphemeralKeyPair;
    if (keyPair == null) {
      throw StateError('Local ephemeral key is not initialized');
    }
    return keyPair;
  }

  SimplePublicKey _requireRemoteEphemeral() {
    final publicKey = _remoteEphemeralPublicKey;
    if (publicKey == null) {
      throw StateError('Remote ephemeral key is not initialized');
    }
    return publicKey;
  }

  Future<Uint8List> _dh(
    SimpleKeyPair localKeyPair,
    SimplePublicKey remotePublicKey,
  ) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: localKeyPair,
      remotePublicKey: remotePublicKey,
    );
    return Uint8List.fromList(await secret.extractBytes());
  }
}

class _NoiseSymmetricState {
  final Chacha20 _cipher = Chacha20.poly1305Aead();
  Uint8List chainingKey;
  Uint8List handshakeHash;
  Uint8List? cipherKey;
  int nonce = 0;

  _NoiseSymmetricState._({
    required this.chainingKey,
    required this.handshakeHash,
  });

  static Future<_NoiseSymmetricState> initialize() async {
    final protocolName = utf8.encode(_noiseProtocolName);
    final initialHash = Uint8List(32);
    if (protocolName.length <= 32) {
      initialHash.setRange(0, protocolName.length, protocolName);
    } else {
      initialHash.setAll(0, (await Sha256().hash(protocolName)).bytes);
    }
    return _NoiseSymmetricState._(
      chainingKey: Uint8List.fromList(initialHash),
      handshakeHash: Uint8List.fromList(initialHash),
    );
  }

  Future<void> mixHash(List<int> data) async {
    final builder = BytesBuilder()
      ..add(handshakeHash)
      ..add(data);
    handshakeHash = Uint8List.fromList((await Sha256().hash(
      builder.toBytes(),
    ))
        .bytes);
  }

  Future<void> mixKey(List<int> inputKeyMaterial) async {
    final outputs = await _hkdf2(chainingKey, inputKeyMaterial);
    chainingKey = outputs.$1;
    cipherKey = outputs.$2;
    nonce = 0;
  }

  Future<Uint8List> encryptAndHash(List<int> plaintext) async {
    final key = cipherKey;
    if (key == null) {
      final cleartext = Uint8List.fromList(plaintext);
      await mixHash(cleartext);
      return cleartext;
    }
    final secretBox = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _noiseNonce(nonce++),
      aad: handshakeHash,
    );
    final ciphertext = secretBox.concatenation(nonce: false);
    await mixHash(ciphertext);
    return ciphertext;
  }

  Future<Uint8List> decryptAndHash(Uint8List ciphertext) async {
    final key = cipherKey;
    if (key == null) {
      await mixHash(ciphertext);
      return Uint8List.fromList(ciphertext);
    }
    if (ciphertext.length < _aeadMacLength) {
      throw const FormatException('Noise ciphertext is truncated');
    }
    final secretBox = _secretBoxWithoutNonce(
      ciphertext,
      nonce: _noiseNonce(nonce++),
    );
    final plaintext = await _cipher.decrypt(
      secretBox,
      secretKey: SecretKey(key),
      aad: handshakeHash,
    );
    await mixHash(ciphertext);
    return Uint8List.fromList(plaintext);
  }

  Future<_NoiseTransportSession> split({required bool initiator}) async {
    final outputs = await _hkdf2(chainingKey, const []);
    return _NoiseTransportSession(
      sendKey: initiator ? outputs.$1 : outputs.$2,
      receiveKey: initiator ? outputs.$2 : outputs.$1,
    );
  }
}

class _NoiseTransportSession {
  final Chacha20 _cipher = Chacha20.poly1305Aead();
  final Uint8List sendKey;
  final Uint8List receiveKey;
  final Set<int> _receivedNonces = {};
  final List<int> _receivedNonceOrder = [];
  int _sendNonce = 0;

  _NoiseTransportSession({
    required this.sendKey,
    required this.receiveKey,
  });

  Future<Uint8List> encryptPayload(
    GrassrootsPacket packet,
    Uint8List senderPubkey,
  ) async {
    final nonce = _sendNonce++;
    final nonceBytes = _nonceBytes(nonce);
    final secretBox = await _cipher.encrypt(
      packet.payload,
      secretKey: SecretKey(sendKey),
      nonce: _aeadNonce(nonce),
      aad: _applicationAad(packet, senderPubkey),
    );
    return Uint8List.fromList([
      _applicationPayloadVersion,
      ...nonceBytes,
      ...secretBox.concatenation(nonce: false),
    ]);
  }

  Future<Uint8List> decryptPayload(
    GrassrootsPacket packet,
    Uint8List senderPubkey,
  ) async {
    final payload = packet.payload;
    if (payload.length < 1 + 8 + _aeadMacLength) {
      throw const FormatException('Secure payload is truncated');
    }
    if (payload[0] != _applicationPayloadVersion) {
      throw FormatException(
          'Unsupported secure payload version: ${payload[0]}');
    }

    final nonce = _nonceFromBytes(payload.sublist(1, 9));
    if (_receivedNonces.contains(nonce)) {
      throw StateError('Replay detected for secure payload nonce $nonce');
    }

    final ciphertext = payload.sublist(9);
    final secretBox = _secretBoxWithoutNonce(
      ciphertext,
      nonce: _aeadNonce(nonce),
    );
    final clear = await _cipher.decrypt(
      secretBox,
      secretKey: SecretKey(receiveKey),
      aad: _applicationAad(packet, senderPubkey),
    );
    _rememberReceivedNonce(nonce);
    return Uint8List.fromList(clear);
  }

  void _rememberReceivedNonce(int nonce) {
    _receivedNonces.add(nonce);
    _receivedNonceOrder.add(nonce);
    if (_receivedNonceOrder.length <= 2048) return;
    final removed = _receivedNonceOrder.removeAt(0);
    _receivedNonces.remove(removed);
  }
}

Future<(Uint8List, Uint8List)> _hkdf2(
    List<int> chainingKey, List<int> ikm) async {
  final hmac = Hmac.sha256();
  final tempKey = (await hmac.calculateMac(
    ikm,
    secretKey: SecretKey(chainingKey),
  ))
      .bytes;
  final output1 = (await hmac.calculateMac(
    const [1],
    secretKey: SecretKey(tempKey),
  ))
      .bytes;
  final output2Input = Uint8List.fromList([...output1, 2]);
  final output2 = (await hmac.calculateMac(
    output2Input,
    secretKey: SecretKey(tempKey),
  ))
      .bytes;
  return (Uint8List.fromList(output1), Uint8List.fromList(output2));
}

Uint8List _encodeHandshakePayload(
  _NoiseHandshakeMessage message,
  Uint8List body,
) {
  return Uint8List.fromList([
    _handshakePayloadVersion,
    message.value,
    ...body,
  ]);
}

(_NoiseHandshakeMessage, Uint8List) _decodeHandshakePayload(Uint8List payload) {
  if (payload.length < 2) {
    throw const FormatException('Noise handshake payload is truncated');
  }
  if (payload[0] != _handshakePayloadVersion) {
    throw FormatException('Unsupported Noise payload version: ${payload[0]}');
  }
  return (
    _NoiseHandshakeMessage.fromValue(payload[1]),
    Uint8List.fromList(payload.sublist(2)),
  );
}

SecretBox _secretBoxWithoutNonce(Uint8List data, {required Uint8List nonce}) {
  final macOffset = data.length - _aeadMacLength;
  return SecretBox(
    Uint8List.fromList(data.sublist(0, macOffset)),
    nonce: nonce,
    mac: Mac(Uint8List.fromList(data.sublist(macOffset))),
  );
}

Uint8List _noiseNonce(int nonce) => _aeadNonce(nonce);

Uint8List _aeadNonce(int nonce) {
  final result = Uint8List(12);
  final view = ByteData.view(result.buffer);
  view.setUint64(4, nonce, Endian.little);
  return result;
}

Uint8List _nonceBytes(int nonce) {
  final result = Uint8List(8);
  ByteData.view(result.buffer).setUint64(0, nonce, Endian.little);
  return result;
}

int _nonceFromBytes(Uint8List nonceBytes) {
  if (nonceBytes.length != 8) {
    throw ArgumentError('Nonce must be 8 bytes');
  }
  return ByteData.view(
    nonceBytes.buffer,
    nonceBytes.offsetInBytes,
    nonceBytes.lengthInBytes,
  ).getUint64(0, Endian.little);
}

/// Application AEAD AAD: binds the ciphertext to its type, sender, recipient
/// and packet id — but NOT to ttl/timestamp. TTL is mutated by every relay, so
/// it cannot be authenticated end-to-end. [senderPubkey] is the originator: the
/// local identity on encrypt, the session peer on (trial-)decrypt.
Uint8List _applicationAad(
  GrassrootsPacket packet,
  Uint8List senderPubkey,
) {
  final recipient = packet.recipientPubkey ?? Uint8List(32);
  final packetId = _uuidToBytes(packet.packetId);
  final data = ByteData(1 + 32 + 32 + 16);
  var offset = 0;
  data.setUint8(offset++, packet.type.value);
  final bytes = data.buffer.asUint8List();
  bytes.setRange(offset, offset + 32, senderPubkey);
  offset += 32;
  bytes.setRange(offset, offset + 32, recipient);
  offset += 32;
  bytes.setRange(offset, offset + 16, packetId);
  return bytes;
}

Uint8List _uuidToBytes(String uuid) {
  final hex = uuid.replaceAll('-', '');
  if (hex.length != 32) {
    throw ArgumentError('Packet ID must be a UUID: $uuid');
  }
  final bytes = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return bytes;
}

String _hex(Uint8List bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
