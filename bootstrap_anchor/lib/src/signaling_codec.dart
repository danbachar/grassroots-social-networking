import 'dart:typed_data';

/// Signaling message types — identical to the client-side SignalingType.
enum SignalingType {
  addrQuery(0x02),
  addrResponse(0x03),
  punchRequest(0x04),
  punchInitiate(0x05),
  punchReady(0x06),
  addrReflect(0x07),
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

sealed class SignalingMessage {
  SignalingType get type;
}

class AddrQueryMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.addrQuery;
  final Uint8List targetPubkey;
  AddrQueryMessage({required this.targetPubkey});
}

class AddrResponseMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.addrResponse;
  final Uint8List targetPubkey;
  final String? ip;
  final int? port;
  bool get found => ip != null && port != null;
  AddrResponseMessage({required this.targetPubkey, this.ip, this.port});
}

class PunchRequestMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.punchRequest;
  final Uint8List targetPubkey;
  PunchRequestMessage({required this.targetPubkey});
}

class PunchInitiateMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.punchInitiate;
  final Uint8List peerPubkey;
  final String ip;
  final int port;
  PunchInitiateMessage(
      {required this.peerPubkey, required this.ip, required this.port});
}

class PunchReadyMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.punchReady;
  final Uint8List peerPubkey;
  PunchReadyMessage({required this.peerPubkey});
}

class AddrReflectMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.addrReflect;
  final String ip;
  final int port;
  AddrReflectMessage({required this.ip, required this.port});
}

/// Owner pushes their full friend list to the anchor server.
class FriendsSyncMessage extends SignalingMessage {
  @override
  SignalingType get type => SignalingType.friendsSync;
  final List<FriendsSyncEntry> friends;
  FriendsSyncMessage({required this.friends});
}

class FriendsSyncEntry {
  final Uint8List pubkey;
  final String nickname;
  FriendsSyncEntry({required this.pubkey, required this.nickname});
}

// ===== Codec =====

/// Binary encoder/decoder for signaling messages.
/// Wire-compatible with the Flutter client's SignalingCodec.
class SignalingCodec {
  const SignalingCodec();

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

  // ===== Encoding =====

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

  AddrQueryMessage _decodeAddrQuery(Uint8List data) {
    if (data.length < 32) {
      throw const FormatException('AddrQuery payload too short');
    }
    return AddrQueryMessage(
        targetPubkey: Uint8List.fromList(data.sublist(0, 32)));
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
    return AddrResponseMessage(targetPubkey: targetPubkey, ip: ip, port: port);
  }

  PunchRequestMessage _decodePunchRequest(Uint8List data) {
    if (data.length < 32) {
      throw const FormatException('PunchRequest payload too short');
    }
    return PunchRequestMessage(
        targetPubkey: Uint8List.fromList(data.sublist(0, 32)));
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
    return PunchInitiateMessage(peerPubkey: peerPubkey, ip: ip, port: port);
  }

  PunchReadyMessage _decodePunchReady(Uint8List data) {
    if (data.length < 32) {
      throw const FormatException('PunchReady payload too short');
    }
    return PunchReadyMessage(
        peerPubkey: Uint8List.fromList(data.sublist(0, 32)));
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
