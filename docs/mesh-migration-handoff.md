# Mesh migration — handoff brief

Self-contained brief so a fresh session (cloud or local) can continue the
direct-delivery → opportunistic-mesh migration without the original chat.

**Branch:** `tum-implementation` (WIP commit `55f1d8e`). **The repo does not
compile yet** — the wire-format change has been made but its call sites have
not. Drive `dart analyze` to find every break, then `flutter test`.

## Goal (locked decisions)

Replace direct-delivery with an **opportunistic BLE mesh**:
- **Open managed flooding.** Every node relays any packet toward its recipient
  ID — TTL-bounded, `BloomFilter`-deduplicated — regardless of whether it knows
  the sender/recipient. (Reverses the old "never relay for arbitrary peers".)
- **Store-carry-forward (DTN).** A relay caches packets whose recipient is not
  currently in range and re-floods when that recipient reappears. Bounded +
  age-expiring; add per-neighbor relay rate-limiting.
- **Sender-anonymous envelope.** The outer header carries only the recipient ID
  (no sender, no whole-packet signature). The body is Noise-sealed to the
  recipient; sender identity + content are visible only to the recipient.
- **BLE mesh only.** UDP/Internet stays direct point-to-point.
- See CLAUDE.md → "Opportunistic Mesh & Store-Carry-Forward" and
  "Mesh Envelope & Trust" (already written).

## Done (stages 1–3, in `55f1d8e`)

1. **CLAUDE.md + `lib/src/transport/transport.dart`** rewritten for the mesh.
2. **`lib/src/models/packet.dart`** — new 58-byte header
   `type|ttl|timestamp|recipientPubkey(32)|packetId(16)|payloadLen`. Removed
   `senderPubkey`, `signature`, `getSignableBytes`, `signatureOffset`. Kept
   `decrementTtl`, `isBroadcast`, `peekPayloadLength` (offset now 54).
   `maxPayloadSize` now 442.
3. **`lib/src/protocol/protocol_handler.dart`** — removed whole-packet
   `signPacket`/`verifyPacket`. ANNOUNCE payload now ends with an Ed25519
   signature over its body (`_signAnnounceBody`), verified in `decodeAnnounce`
   (`_verifyAnnounceBody`); throws on a bad signature. `createMessagePacket` /
   `createAckPacket` / `createReadReceiptPacket` no longer take a sender.

## Remaining (stages 4–10)

**4. Noise layer (`lib/src/session/noise_session_manager.dart`)** — security-critical.
   - Key sessions by **pubkey only** (drop `transport` from `_SessionKey`; a mesh
     session is path-independent). Drop `resetTransport`.
   - **Application AAD** (`_applicationAad`): rebuild as `type ‖ recipientPubkey ‖
     packetId ‖ senderPubkey`. **DROP `ttl`** (relays mutate it → otherwise
     decryption fails) and drop `timestamp`. Thread `senderPubkey` explicitly:
     encrypt side uses `identity.publicKey`; decrypt side uses the session peer's
     pubkey. Update `_NoiseTransportSession.encryptPayload/decryptPayload`
     signatures accordingly.
   - Replace `decryptPacket(by header sender)` with **`trialDecrypt(packet) ->
     (clearPacket, senderPubkey)?`**: try each active session; the AEAD tag
     identifies the right one. A wrong-session attempt must NOT poison nonce
     state (current code only records the nonce after a successful decrypt — keep
     that property).
   - `encryptPacket({required remotePubkey})`: drop the `transport` param and the
     (now-removed) `signature` field in its `copyWith`.
   - **Handshakes are NEIGHBOR-LOCAL (not flooded).** `handleHandshakePacket`
     takes `remotePubkey` as a parameter supplied by the coordinator (resolved
     from the inbound BLE path → the peer's pubkey from their verified
     self-signed ANNOUNCE) instead of reading a header sender. `_verifyRemoteStatic`
     still binds the Noise static to that known identity.
   - **Deferred (do NOT attempt here):** establishing a session between two peers
     who have NEVER been in direct BLE range, purely over multi-hop. Flooded XX
     can't address the responder's reply. Needs Noise IK (or XX + broadcast-msg2
     + handshake-correlation id). Leave a TODO.

**5. Router (`lib/src/routing/message_router.dart`)**
   - Dedup ALL packet types by `packetId` via `BloomFilter` (loop prevention).
   - **Relay:** if recipient != us and not broadcast and `ttl > 1`, `decrementTtl`
     and rebroadcast to all BLE neighbors except the inbound path. Relay happens
     for opaque packets WITHOUT decrypting/verifying.
   - Replace `packet.senderPubkey` usage with `trialDecrypt` results; deliver
     `onMessageReceived(packetId, senderPubkey, payload, transport)` using the
     recovered sender.
   - Verify ANNOUNCE via the payload signature (now inside `decodeAnnounce`);
     remove the old whole-packet `verifyPacket` call.

**6. DTN store-carry-forward** — new subsystem. Bounded, age-expiring store of
   relayed packets keyed by recipient; re-flood on that recipient's
   ANNOUNCE/peer-connected. Cap store size, per-recipient depth, per-neighbor
   relay rate.

**7. Coordinator (`lib/src/grassroots_network.dart`)** — the big file.
   - Send path: Noise-encrypt then **flood** into the BLE mesh (`broadcast`), with
     a direct-neighbor fast path. Keep the sender's own outbound queue.
   - Resolve inbound BLE path → peer pubkey and pass it to the Noise handshake
     handlers (replaces header-sender-based session keying). Sign ANNOUNCE
     payloads (handled in ProtocolHandler now). Remove `resetTransport` calls.
   - UDP stays direct (no flooding).

**8. Transports (`transport_service.dart`, `ble_transport_service.dart`,
   `udp_transport_service.dart`)** — BLE send becomes `broadcast`-into-mesh
   (`broadcast(data, {excludePeerIds})` already exists). UDP peer identity now
   comes from the Noise session/ANNOUNCE, not the header sender
   (`onUdpPeerIdentified` path).

**9. `bootstrap_anchor/`** — mirrors `packet.dart`, `protocol.dart`,
   `noise_session_manager.dart`, `signaling_codec.dart`. Apply the same envelope +
   Noise AAD + identity changes so the rendezvous server still interoperates. The
   anchor is a direct signaling peer, NOT a mesh relay.

**10. Tests** — ~28 files reference the old format (`senderPubkey`, `signature`,
   `verifyPacket`, the old `GrassrootsPacket(...)` shape). Update them; add
   mesh-relay + DTN + trial-decrypt + neighbor-local-handshake tests. Run
   `dart analyze` to zero errors, then `flutter test` green.

## Verification

```
dart analyze
flutter test
```
Treat the Noise/handshake changes as security-critical — review carefully; do
not auto-merge.
