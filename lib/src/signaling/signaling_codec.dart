import 'dart:typed_data';

/// Signaling message types for well-connected friend coordination.
///
/// These ride inside [BitchatPacket] payloads with [PacketType.signaling].
/// Authentication is handled by the outer BitchatPacket's Ed25519 signature.
enum SignalingType {
  /// "What's the address of pubkey X?" — agent → friend
  addrQuery(0x02),

  /// "Pubkey X is at ip:port Y" (or not found) — friend → agent
  addrResponse(0x03),

  /// "Please coordinate a hole-punch with pubkey X" — agent → friend
  punchRequest(0x04),

  /// "Start sending UDP to ip:port Y for hole-punch" — friend → agent
  punchInitiate(0x05),

  /// "I've opened my NAT, tell the other side" — agent → friend
  punchReady(0x06),

  /// "Your actual public address is ip:port" — friend → agent (triggered by ANNOUNCE)
  addrReflect(0x07),

  /// "Here's my full friend list" — owner → anchor server
  friendsSync(0x08);

  final int value;
  const SignalingType(this.value);

  static SignalingType fromValue(int value) {
    return SignalingType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => throw ArgumentError('Unknown signaling type: $value'),
    );
  }
}

// ===== Message classes =====

/// Base class for decoded signaling messages.
sealed class SignalingMessage {
  SignalingType get type;
}

/// Agent asks a well-connected friend for another peer's address.
class AddrQueryMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.addrQuery;

  /// The public key of the peer whose address we want (32 bytes).
  final Uint8List targetPubkey;

  AddrQueryMessage({required this.targetPubkey});

  @override
  String toString() =>
      'AddrQuery(target: ${targetPubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...)';
}

/// Response to an address query: the peer's address (or not found).
class AddrResponseMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.addrResponse;

  /// The public key that was queried (32 bytes).
  final Uint8List targetPubkey;

  /// The peer's IP address, or null if not found.
  final String? ip;

  /// The peer's UDP port, or null if not found.
  final int? port;

  /// Whether the peer was found in the address table.
  bool get found => ip != null && port != null;

  AddrResponseMessage({
    required this.targetPubkey,
    this.ip,
    this.port,
  });

  @override
  String toString() =>
      'AddrResponse(target: ${targetPubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}..., '
      '${found ? "$ip:$port" : "not found"})';
}

/// Agent requests a well-connected friend to coordinate a hole-punch.
class PunchRequestMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.punchRequest;

  /// The public key of the peer we want to punch through to (32 bytes).
  final Uint8List targetPubkey;

  PunchRequestMessage({required this.targetPubkey});

  @override
  String toString() =>
      'PunchRequest(target: ${targetPubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...)';
}

/// Well-connected friend tells agent to start hole-punching to a peer.
class PunchInitiateMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.punchInitiate;

  /// The public key of the peer to punch toward (32 bytes).
  final Uint8List peerPubkey;

  /// The peer's IP address to send punch packets to.
  final String ip;

  /// The peer's UDP port to send punch packets to.
  final int port;

  PunchInitiateMessage({
    required this.peerPubkey,
    required this.ip,
    required this.port,
  });

  @override
  String toString() =>
      'PunchInitiate(peer: ${peerPubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}..., '
      '$ip:$port)';
}

/// Agent tells a well-connected friend that its NAT is open.
class PunchReadyMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.punchReady;

  /// The public key of the peer we're punching toward (32 bytes).
  final Uint8List peerPubkey;

  PunchReadyMessage({required this.peerPubkey});

  @override
  String toString() =>
      'PunchReady(peer: ${peerPubkey.sublist(0, 4).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}...)';
}

/// Well-connected friend reflects the agent's observed public address.
///
/// When a well-connected friend receives an ANNOUNCE over UDP, it compares
/// the claimed address in the payload with the observed source address on the
/// UDX connection. If they differ, it sends ADDR_REFLECT back with the actual
/// address — letting the agent learn its true NAT-translated address,
/// including the correct external port.
class AddrReflectMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.addrReflect;

  /// The agent's observed public IP address.
  final String ip;

  /// The agent's observed public UDP port.
  final int port;

  AddrReflectMessage({required this.ip, required this.port});

  @override
  String toString() => 'AddrReflect($ip:$port)';
}

/// Owner pushes their full friend list to the anchor server.
///
/// Sent on first connection to the anchor and whenever the friend list changes.
/// The anchor replaces its entire friend list with this data.
class FriendsSyncMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.friendsSync;

  /// List of friends to sync.
  final List<FriendsSyncEntry> friends;

  FriendsSyncMessage({required this.friends});

  @override
  String toString() => 'FriendsSync(${friends.length} friends)';
}

/// A single friend entry in a FRIENDS_SYNC message.
class FriendsSyncEntry {
  final Uint8List pubkey;
  final String nickname;

  FriendsSyncEntry({required this.pubkey, required this.nickname});
}

// ===== Codec =====

/// Binary encoder/decoder for signaling messages.
///
/// Wire formats:
///
/// ```
/// ADDR_QUERY     : type(1) + targetPubkey(32)
/// ADDR_RESPONSE  : type(1) + targetPubkey(32) + found(1) + [ipLen(2) + ipBytes + port(2)]
/// PUNCH_REQUEST  : type(1) + targetPubkey(32)
/// PUNCH_INITIATE : type(1) + peerPubkey(32) + ipLen(2) + ipBytes + port(2)
/// PUNCH_READY    : type(1) + peerPubkey(32)
/// ADDR_REFLECT   : type(1) + ipLen(2) + ipBytes + port(2)
/// ```
class SignalingCodec {
  const SignalingCodec();

  // ===== Encoding =====

  Uint8List encode(SignalingMessage msg) {
    return switch (msg) {
      AddrQueryMessage() => _encodeAddrQuery(msg),
      AddrResponseMessage() => _encodeAddrResponse(msg),
      PunchRequestMessage() => _encodePunchRequest(msg),
      PunchInitiateMessage() => _encodePunchInitiate(msg),
      PunchReadyMessage() => _encodePunchReady(msg),
      AddrReflectMessage() => _encodeAddrReflect(msg),
      FriendsSyncMessage() => _encodeFriendsSync(msg),
    };
  }

  Uint8List _encodeAddrQuery(AddrQueryMessage msg) {
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.addrQuery.value);
    buffer.add(msg.targetPubkey);
    return buffer.toBytes();
  }

  Uint8List _encodeAddrResponse(AddrResponseMessage msg) {
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.addrResponse.value);
    buffer.add(msg.targetPubkey);
    buffer.addByte(msg.found ? 1 : 0);
    if (msg.found) {
      final ipBytes = Uint8List.fromList(msg.ip!.codeUnits);
      _writeUint16(buffer, ipBytes.length);
      buffer.add(ipBytes);
      _writeUint16(buffer, msg.port!);
    }
    return buffer.toBytes();
  }

  Uint8List _encodePunchRequest(PunchRequestMessage msg) {
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.punchRequest.value);
    buffer.add(msg.targetPubkey);
    return buffer.toBytes();
  }

  Uint8List _encodePunchInitiate(PunchInitiateMessage msg) {
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.punchInitiate.value);
    buffer.add(msg.peerPubkey);
    final ipBytes = Uint8List.fromList(msg.ip.codeUnits);
    _writeUint16(buffer, ipBytes.length);
    buffer.add(ipBytes);
    _writeUint16(buffer, msg.port);
    return buffer.toBytes();
  }

  Uint8List _encodePunchReady(PunchReadyMessage msg) {
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.punchReady.value);
    buffer.add(msg.peerPubkey);
    return buffer.toBytes();
  }

  Uint8List _encodeAddrReflect(AddrReflectMessage msg) {
    final ipBytes = Uint8List.fromList(msg.ip.codeUnits);
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.addrReflect.value);
    _writeUint16(buffer, ipBytes.length);
    buffer.add(ipBytes);
    _writeUint16(buffer, msg.port);
    return buffer.toBytes();
  }

  // ===== Decoding =====

  /// Decode a signaling payload into a [SignalingMessage].
  ///
  /// Throws [FormatException] if the payload is malformed.
  SignalingMessage decode(Uint8List data) {
    if (data.isEmpty) {
      throw const FormatException('Empty signaling payload');
    }

    final type = SignalingType.fromValue(data[0]);
    final payload = Uint8List.sublistView(data, 1);

    return switch (type) {
      SignalingType.addrQuery => _decodeAddrQuery(payload),
      SignalingType.addrResponse => _decodeAddrResponse(payload),
      SignalingType.punchRequest => _decodePunchRequest(payload),
      SignalingType.punchInitiate => _decodePunchInitiate(payload),
      SignalingType.punchReady => _decodePunchReady(payload),
      SignalingType.addrReflect => _decodeAddrReflect(payload),
      SignalingType.friendsSync => _decodeFriendsSync(payload),
    };
  }

  AddrQueryMessage _decodeAddrQuery(Uint8List data) {
    if (data.length < 32) {
      throw const FormatException('AddrQuery payload too short');
    }
    return AddrQueryMessage(
      targetPubkey: Uint8List.fromList(data.sublist(0, 32)),
    );
  }

  AddrResponseMessage _decodeAddrResponse(Uint8List data) {
    if (data.length < 33) {
      throw const FormatException('AddrResponse payload too short');
    }
    final targetPubkey = Uint8List.fromList(data.sublist(0, 32));
    final found = data[32] != 0;

    if (!found) {
      return AddrResponseMessage(targetPubkey: targetPubkey);
    }

    var offset = 33;
    final ipLen = _readUint16(data, offset);
    offset += 2;
    final ip = String.fromCharCodes(data.sublist(offset, offset + ipLen));
    offset += ipLen;
    final port = _readUint16(data, offset);

    return AddrResponseMessage(
      targetPubkey: targetPubkey,
      ip: ip,
      port: port,
    );
  }

  PunchRequestMessage _decodePunchRequest(Uint8List data) {
    if (data.length < 32) {
      throw const FormatException('PunchRequest payload too short');
    }
    return PunchRequestMessage(
      targetPubkey: Uint8List.fromList(data.sublist(0, 32)),
    );
  }

  PunchInitiateMessage _decodePunchInitiate(Uint8List data) {
    if (data.length < 36) {
      throw const FormatException('PunchInitiate payload too short');
    }
    final peerPubkey = Uint8List.fromList(data.sublist(0, 32));
    var offset = 32;
    final ipLen = _readUint16(data, offset);
    offset += 2;
    final ip = String.fromCharCodes(data.sublist(offset, offset + ipLen));
    offset += ipLen;
    final port = _readUint16(data, offset);

    return PunchInitiateMessage(
      peerPubkey: peerPubkey,
      ip: ip,
      port: port,
    );
  }

  PunchReadyMessage _decodePunchReady(Uint8List data) {
    if (data.length < 32) {
      throw const FormatException('PunchReady payload too short');
    }
    return PunchReadyMessage(
      peerPubkey: Uint8List.fromList(data.sublist(0, 32)),
    );
  }

  AddrReflectMessage _decodeAddrReflect(Uint8List data) {
    var offset = 0;
    final ipLen = _readUint16(data, offset);
    offset += 2;
    final ip = String.fromCharCodes(data.sublist(offset, offset + ipLen));
    offset += ipLen;
    final port = _readUint16(data, offset);
    return AddrReflectMessage(ip: ip, port: port);
  }

  Uint8List _encodeFriendsSync(FriendsSyncMessage msg) {
    final buffer = BytesBuilder();
    buffer.addByte(SignalingType.friendsSync.value);
    _writeUint16(buffer, msg.friends.length);
    for (final friend in msg.friends) {
      buffer.add(friend.pubkey);
      final nickBytes = Uint8List.fromList(friend.nickname.codeUnits);
      buffer.addByte(nickBytes.length);
      buffer.add(nickBytes);
    }
    return buffer.toBytes();
  }

  FriendsSyncMessage _decodeFriendsSync(Uint8List data) {
    if (data.length < 2) {
      throw const FormatException('FriendsSync payload too short');
    }
    var offset = 0;
    final count = _readUint16(data, offset);
    offset += 2;

    final friends = <FriendsSyncEntry>[];
    for (var i = 0; i < count; i++) {
      if (offset + 33 > data.length) {
        throw FormatException('FriendsSync truncated at entry $i');
      }
      final pubkey = Uint8List.fromList(data.sublist(offset, offset + 32));
      offset += 32;
      final nickLen = data[offset];
      offset += 1;
      if (offset + nickLen > data.length) {
        throw FormatException('FriendsSync nickname truncated at entry $i');
      }
      final nickname =
          String.fromCharCodes(data.sublist(offset, offset + nickLen));
      offset += nickLen;
      friends.add(FriendsSyncEntry(pubkey: pubkey, nickname: nickname));
    }
    return FriendsSyncMessage(friends: friends);
  }

  // ===== Helpers =====

  void _writeUint16(BytesBuilder buffer, int value) {
    buffer.addByte((value >> 8) & 0xFF);
    buffer.addByte(value & 0xFF);
  }

  int _readUint16(Uint8List data, int offset) {
    return (data[offset] << 8) | data[offset + 1];
  }
}
