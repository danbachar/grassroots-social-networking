# Wire-format tightening: 3-type outer envelope + inner secure frame

Status: IN PROGRESS. This doc is the resumable spec + checklist for the refactor.
Goal (user-authorised): collapse the 18-value wire `PacketType` to **3** — `announce`,
`noiseHandshake`, `secure` — moving content-type and fragmentation *inside* the sealed
payload. This also closes a metadata leak (relays currently see `secureAck` vs
`secureMessage` vs `secureSignaling` vs `secureFragment*` in the header).

## Target wire enum (`lib/src/models/packet.dart`)
```dart
enum PacketType { announce(0x01), noiseHandshake(0x02), secure(0x03); }
```
Delete the four extensions: `usesSessionSecurity`, `isSessionEncrypted`,
`secureVariant`, `clearVariant`. The 58-byte header layout is unchanged.

## New inner frame (`lib/src/models/secure_frame.dart`, NEW)
Plaintext that gets sealed inside a `secure` packet:
```
[0]      contentType (1)   ContentType: message|ack|readReceipt|signaling
[1-2]    fragIndex   (2 BE) 0-based
[3-4]    fragCount   (2 BE) >=1  (1 = not fragmented)
[5-20]   messageId   (16)   logical message id (binary UUID)
[21..]   chunk              content bytes for this fragment (whole payload if fragCount==1)
```
`ContentType` enum (inner, not on the wire): `message(0x01) ack(0x02) readReceipt(0x03) signaling(0x04)`.
`nack` is DROPPED (dead: never created/sent).

## Identity/dedup model
- **Outer `packetId`** (16B header): per-wire-packet id — mesh loop/relay dedup (unchanged). Each fragment gets its own.
- **Inner `messageId`** (frame): logical app id — reassembly + ACK correlation + `onMessageReceived` id.
- Single message: 1 wire packet, fresh outer packetId, frame.messageId = app messageId, fragCount=1.
- Fragmented: N wire packets (distinct packetIds), all frames share messageId, fragIndex 0..N-1, fragCount=N.

## Sealing (`noise_session_manager.dart`)
- `encryptPacket(pkt)`: `if (pkt.type != secure) return pkt;` else seal payload, keep `type: secure` (no variant swap).
- `trialDecrypt(pkt)`: `if (pkt.type != secure) return null;` decrypt → `(pkt.copyWith(payload: plaintext), sender)`, type stays `secure`.
- AAD (`_applicationAad`) binds {type(=secure, constant), sender, recipient, packetId}. Drop the `clearType` param from encrypt/decryptPayload (use `packet.type`). Content type is authenticated because it's inside the AEAD-protected plaintext.

## Fragmentation (`fragment_handler.dart`) — rewrite to be frame-based
- Chunker: `List<Uint8List> chunk(Uint8List payload)` split by `maxFragmentPayload` (270). `needsFragmentation` unchanged (>320).
- Reassembler keyed by messageId: `accept(messageId, fragIndex, fragCount, chunk) -> Uint8List?` (returns full payload on completion). Keep 2-min timeout + cleanup.
- Delete GrassrootsPacket/PacketType coupling + the fragmentStart/Continue/End sub-header codecs.

## Content construction (`protocol_handler.dart`)
- `createMessagePacket`/`createAckPacket`/`createReadReceiptPacket` (and signaling in coordinator) now: build a `SecureFrame` (contentType, messageId, fragIndex/Count, chunk) → wrap in `GrassrootsPacket(type: secure, recipient, packetId, payload: frame.encode())`. ANNOUNCE unchanged (still self-signed, type announce).

## Router (`message_router.dart`)
- Outer dispatch: `announce` → handleAnnounce; `noiseHandshake` → handshake; `secure` → trialDecrypt → decode frame → dispatch on `frame.contentType`.
- For `message`: if fragCount>1 feed reassembler (dedupe delivery on messageId); else deliver chunk. `onMessageReceived(messageId, sender, payload)`, `onAckRequested(sender, messageId)`.
- `ack`/`readReceipt`: chunk = utf8(messageId being acked) — unchanged handlers, fed from frame.chunk.
- `signaling`: `onSignalingReceived(sender, frame.chunk, ...)`.
- Relay/loop dedupe still on outer packetId (pre-decrypt). Delivery-once for messages on inner messageId.

## Coordinator (`grassroots_network.dart`)
- Build `secure` packets for all content (message/ack/readReceipt/signaling). `_sealedPacketBytesForTransport`: `if (type == secure) ensureSession+encryptPacket else serialize`. Fragmented BLE send builds N `secure` frames, seals+floods each. ACK/readReceipt/signaling packet creation → secure frames.
- Keep: ANNOUNCE ttl:1 self-signed; handshake ttl:1; ack correlation via messageId.

## Anchor mirror (`bootstrap_anchor/lib/src/…`)
Mirror exactly: `packet.dart` (enum→3, drop extensions), `noise_session_manager.dart` (seal/unseal), `protocol.dart` (secure frames for ack/signaling), `signaling_handler.dart`/`anchor_server.dart` (dispatch on frame contentType). Add `secure_frame.dart` mirror.

## Tests to update
`test/bitchat_test.dart`, `test/protocol/protocol_handler_test.dart`, `test/protocol/fragment_handler_test.dart`,
`test/routing/message_router_test.dart`, `test/session/noise_session_manager_test.dart`,
`test/integration/protocol_router_integration_test.dart`, + anchor tests.

## Verify
`dart analyze lib` 0 errors; `flutter test` green (client). Then anchor `dart analyze`. Then finalize architecture doc against this new reality.

## Progress
- [x] packet.dart enum (announce/noiseHandshake/secure) + removed 4 extensions
- [x] secure_frame.dart (new): ContentType{message,ack,readReceipt,signaling} + SecureFrame codec (21B header)
- [x] noise_session_manager.dart: encryptPacket/trialDecrypt keep type=secure; AAD drops clearType (uses packet.type); decryptPayload drops clearType param
- [x] fragment_handler.dart: rewritten to framesFor()/accept() over SecureFrame (removed fragment/processFragment/FragmentedMessage/ReassembledMessage)
- [x] protocol_handler.dart: createMessagePacket/createAckPacket/createReadReceiptPacket build secure frames
- [x] message_router.dart: dispatch on SecureFrame.contentType; _handleMessageFrame + reassembly post-decrypt; _handleAck/_handleReadReceipt/_handleSignaling take Uint8List chunk
- [x] grassroots_network.dart: createMessagePacket(messageId:); _sealedPacketBytesForTransport gate (type==secure); _createSignalingPacket -> secure signaling frame; _sendFragmentedViaBle -> framesFor
- [x] **client `dart analyze lib` = 0 errors (47 pre-existing info lints). LIB COMPILES.**  <-- CHECKPOINT REACHED
- [x] **client tests rewritten (all 7 files) — `dart analyze lib test` = 0 errors; `flutter test` = 587/587 PASS.** CLIENT REFACTOR COMPLETE.
      Notable behavioural reinterpretations made during the test rewrite (verified consistent with the new design):
        - fragment_handler: a sub-threshold payload used to make fragment() THROW; framesFor() now returns exactly ONE non-fragmented frame (accept() returns its chunk immediately).
        - router: the old "NACK addressed to us is ignored" test → "signaling content does not fire message/ack/readReceipt handlers" (nack removed).
        - router: "drops cleartext message addressed to us" → "drops an UNSEALED secure packet" (no cleartext content type exists to construct anymore).
        - router: onAckRequested now asserts against frame.messageId (not the outer packetId); dedup test confirms 3 wire copies sharing one frame.messageId → 1 delivery + 3 re-ACKs.
- [ ] bootstrap_anchor mirror — DEFERRED by user. NOTE: until mirrored, a refactored client will NOT interop with the anchor (wire formats diverge). Anchor files to change: packet.dart (enum+extensions), noise_session_manager (seal/unseal/AAD), protocol.dart (secure frames), signaling_handler/anchor_server (dispatch on frame); + secure_frame.dart mirror + anchor tests.
- [ ] then: finalize architecture doc against this new reality (re-ground §2 §3 §6 §7 §10 §11)
