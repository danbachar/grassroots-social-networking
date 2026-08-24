import 'dart:typed_data';

import '../models/packet.dart';

/// Wire codec for the sync-on-connect packetId lists carried by
/// the retired id-list [ContentType.syncOffer]/[syncRequest] frames.
/// The current sync frame is a GCS filter — see [encodeSyncFilter].
///
/// Payload format: `[count:1][packetId:16] × count`.
///
/// A single BLE GATT write carries at most 244 bytes (247 floor MTU − 3), and
/// a sealed sync packet costs [syncPacketOverhead] on top of this payload —
/// the same three layers [FragmentHandler] budgets for. Only the packet
/// header was subtracted here originally, which put 11 ids in a 281-byte
/// packet: 37 over. These are WRITE_TYPE_NO_RESPONSE writes, so the stack
/// cannot promote them to a GATT long write — it clamps at MTU−3 and the peer
/// gets an unparseable prefix. Reproduced on hardware 2026-08-10: the sender
/// logged `OVERSIZED sendToPeer 281B > 244B` and the receiver
/// `deserialize failed after 244B … Incomplete payload: expected 223 bytes`.
///
/// Larger sets are chunked into multiple self-contained packets — sync packets
/// are neighbor-local single-hop, so there is no reassembly: each chunk is
/// acted on independently.
const int syncUsableWrite = 247 - 3;

/// Packet header + Noise seal + frame header, per
/// [FragmentHandler] — header + 25 + 21.
const int syncPacketOverhead = GrassrootsPacket.headerSize + 25 + 21;

/// Ids that fit one sealed write: one count byte, then 16 bytes each.
const int maxSyncIdsPerPacket =
    (syncUsableWrite - syncPacketOverhead - 1) ~/ 16;

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
/// Chunk [packetIds] into payloads that each fit a single BLE write. Each
/// chunk becomes one sealed SecureFrame — the ids
/// never travel in the clear.
List<Uint8List> buildSyncPayloads(List<String> packetIds) {
  final out = <Uint8List>[];
  for (var i = 0; i < packetIds.length; i += maxSyncIdsPerPacket) {
    final chunk = packetIds.sublist(
        i,
        (i + maxSyncIdsPerPacket > packetIds.length)
            ? packetIds.length
            : i + maxSyncIdsPerPacket);
    out.add(encodeSyncIds(chunk));
  }
  return out;
}


/// Wire format for a GCS sync filter frame:
/// `[n:2][fromMs:8][toMs:8][filter bytes]`.
///
/// `n` is the element count the reader needs to rebuild the filter's modulus;
/// the two timestamps are the WINDOW the filter covers, as originator-stamped
/// Unix MILLISECONDS — the same clock as a packet's `createdAtMs`, so a
/// responder can compare the two directly. They are 8 bytes each because real
/// epoch-ms (~1.7e12) overflow a uint32 (~4.29e9): a 4-byte field truncated
/// every bound to its low 32 bits, and the responder's full-ms `windowBetween`
/// then matched nothing, delivering nothing. The window is the load-bearing
/// part: a responder answers only with packets whose own creation time falls
/// inside it, so a filter covering a subset of the sender's buffer cannot
/// provoke a re-send of everything outside that subset. Without the bounds,
/// capping the filter would turn it into a duplicate generator.
const int syncFilterHeaderSize = 18;

Uint8List encodeSyncFilter({
  required int n,
  required int fromMs,
  required int toMs,
  required Uint8List filter,
}) {
  final out = Uint8List(syncFilterHeaderSize + filter.length);
  final view = ByteData.view(out.buffer);
  view.setUint16(0, n, Endian.big);
  view.setUint64(2, fromMs, Endian.big);
  view.setUint64(10, toMs, Endian.big);
  out.setRange(syncFilterHeaderSize, out.length, filter);
  return out;
}

({int n, int fromMs, int toMs, Uint8List filter}) decodeSyncFilter(
    Uint8List payload) {
  if (payload.length < syncFilterHeaderSize) {
    throw const FormatException('Sync filter payload too short');
  }
  final view = ByteData.view(payload.buffer, payload.offsetInBytes);
  return (
    n: view.getUint16(0, Endian.big),
    fromMs: view.getUint64(2, Endian.big),
    toMs: view.getUint64(10, Endian.big),
    filter: Uint8List.sublistView(payload, syncFilterHeaderSize),
  );
}
