import 'dart:typed_data';

import '../models/packet.dart';

/// Wire codec for the sync-on-connect packetId lists carried by
/// [PacketType.syncOffer] and [PacketType.syncRequest].
///
/// Payload format: `[count:1][packetId:16] × count`.
///
/// A single BLE GATT write carries at most 244 bytes (247 floor MTU − 3), and
/// the packet header is 58 bytes, leaving 186 for payload → ⌊(186−1)/16⌋ = 11
/// ids per packet. Larger sets are chunked into multiple self-contained
/// packets — sync packets are neighbor-local single-hop, so there is no
/// reassembly: each chunk is acted on independently.
const int maxSyncIdsPerPacket = 11;

/// Encode up to [maxSyncIdsPerPacket] packetId UUID strings as one payload.
Uint8List encodeSyncIds(List<String> packetIds) {
  if (packetIds.length > maxSyncIdsPerPacket) {
    throw ArgumentError(
        'Sync payload holds at most $maxSyncIdsPerPacket ids, '
        'got ${packetIds.length} — chunk first');
  }
  final out = Uint8List(1 + packetIds.length * 16);
  out[0] = packetIds.length;
  for (var i = 0; i < packetIds.length; i++) {
    out.setRange(1 + i * 16, 1 + (i + 1) * 16,
        GrassrootsPacket.uuidToBytes(packetIds[i]));
  }
  return out;
}

/// Decode a sync payload back to packetId UUID strings. A payload whose length
/// disagrees with its count byte is malformed and throws (clean-break rule: no
/// tolerant decoding of hypothetical other versions).
List<String> decodeSyncIds(Uint8List payload) {
  if (payload.isEmpty) {
    throw const FormatException('Sync payload empty');
  }
  final count = payload[0];
  if (count > maxSyncIdsPerPacket) {
    throw FormatException('Sync payload count $count exceeds cap');
  }
  if (payload.length != 1 + count * 16) {
    throw FormatException(
        'Sync payload length ${payload.length} != ${1 + count * 16}');
  }
  return [
    for (var i = 0; i < count; i++)
      GrassrootsPacket.bytesToUuid(
          Uint8List.sublistView(payload, 1 + i * 16, 1 + (i + 1) * 16)),
  ];
}

/// Chunk [packetIds] into sync packets of the given [type] (offer or request).
/// Each packet is neighbor-local: broadcast-addressed with TTL 1 so a relay
/// never forwards it.
List<GrassrootsPacket> buildSyncPackets(
    PacketType type, List<String> packetIds) {
  assert(type == PacketType.syncOffer || type == PacketType.syncRequest);
  final packets = <GrassrootsPacket>[];
  for (var i = 0; i < packetIds.length; i += maxSyncIdsPerPacket) {
    final chunk = packetIds.sublist(
        i,
        (i + maxSyncIdsPerPacket > packetIds.length)
            ? packetIds.length
            : i + maxSyncIdsPerPacket);
    packets.add(GrassrootsPacket(
      type: type,
      ttl: 1, // neighbor-local: never relayed
      payload: encodeSyncIds(chunk),
    ));
  }
  return packets;
}
