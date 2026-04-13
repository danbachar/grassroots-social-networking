# Bitchat Transport — Session Handover

## Context

You are continuing work on `bitchat_transport`, a Flutter peer-to-peer messaging transport layer. Branch: `social-graph-connectivity`. Read `CLAUDE.md` first for project philosophy and architecture.

Three test devices:
- **dan** — iPhone, pubkey `5e8f5c0c...`, port 53740
- **close** — Pixel, pubkey `b20c890c...`, port 58201
- **far** — Pixel, pubkey `402a2f26...`, port 55772

All three are proximate on the same WiFi network. BLE and UDP transports are both active.

## What Works

The core transport is functional: dan↔close via UDP, dan↔far via UDP, close↔far via BLE all communicate successfully. ANNOUNCE, signaling, and hole-punching all work in the happy path.

## Recent Commits (unpushed, need `git push` from host machine)

```
7027ff3 Switch dart_udx to local path dependency for development
61b0b01 Add nearby panel: discovered devices, manual connect, BLE disconnect button
1a44b17 BLE disconnect/blacklist, connectivity filter fix, Logger→debugPrint migration
```

Key changes in these commits:
- `disconnectBlePeer()` / `connectBleDevice()` on Bitchat coordinator
- `BleDeviceBlacklistedAction`/`UnblacklistedAction` + `isBlacklisted` on `DiscoveredPeerState`
- Blacklist checked during auto-connect in `_onDeviceDiscovered()`
- `connectToDevice(deviceId, isManual)` on `BleTransportService`
- Filtered `ConnectivityResult.bluetooth` from `_onConnectivityChanged()` so BLE events don't restart UDP
- Logger → debugPrint across all lib/src (removes logger dependency)
- Nearby panel now shows unconnected discovered devices with manual connect button
- BLE disconnect button on connected peers

## Open Issues (prioritized)

### Issue 1 — Stale Friendships (HIGH)

Dan's phone has friendships with stale keys `1bd62a2e...` and `3ffea159...` from previous installs of close/far. `_discoverUnreachableFriends()` (bitchat.dart:1150-1189) loops every 60s trying to find these ghost peers:

```
query → not found → hole-punch request → timeout (15s) → retry in 60s → repeat forever
```

No exponential backoff exists. The discovery interval `_discoveryRetryInterval` is a flat 60 seconds.

**Fix options:**
- Add exponential backoff to `_lastDiscoveryAttempt` tracking (e.g., 60s → 120s → 240s → cap at 1h)
- Add UI to view/remove friendships
- Add a mechanism to detect and prune friendships where the peer has never responded after N attempts

### Issue 2 — BLE Disconnect Doesn't Actually Work (HIGH)

`disconnectBlePeer()` (bitchat.dart:273-285) only disconnects via `_central`. The `disconnectFromDevice()` method on `BleTransportService` (line 485-487) calls `_central.disconnectFromDevice()` only — it never touches the peripheral side.

Two problems:
1. **Peripheral connections are untouched.** If the remote device connected to *us* as a central (their central → our peripheral), this path does nothing. `ble_peripheral_bondless` doesn't expose a `disconnectCentral(deviceId)` API — BLE peripherals on iOS/Android can't force-disconnect a specific central.
2. **Immediate reconnection.** Even if the central disconnect succeeds, the remote device rediscovers and reconnects within seconds. The blacklist only prevents *our* central's outbound auto-connect — it doesn't stop the *remote device's* central from connecting to our peripheral.

**Fix approach (discussed with Dan):**
Since we have the pubkey→deviceId mapping (`peer.bleCentralDeviceId` / `peer.blePeripheralDeviceId`), the disconnect should:
1. Disconnect the central connection (already done)
2. Remove the deviceId from `_connectedCentrals` on the peripheral side
3. Add a **pubkey-level blacklist** checked when processing incoming ANNOUNCE messages — so even if the remote reconnects at the BLE level, we refuse to identify them and they never enter the `peers` map

Key files:
- `lib/src/bitchat.dart` — `disconnectBlePeer()` at line 273
- `lib/src/transport/ble_transport_service.dart` — `disconnectFromDevice()` at line 485
- `lib/src/ble/ble_peripheral_service.dart` — no single-central disconnect exists
- `lib/src/routing/message_router.dart` — ANNOUNCE processing (where blacklist check should go)

### Issue 3 — Hole-Punch Relay Requires Mutual Friendship (MEDIUM)

`_handlePunchRequest()` (signaling_service.dart:356-403) requires the *target* peer to also be a friend of the relay node (line 365-368):

```dart
final targetPeer = store.state.peers.getPeerByPubkeyHex(targetHex);
if (targetPeer == null || !targetPeer.isFriend) {
  debugPrint('Punch request for non-friend target ..., ignoring');
  return;
}
```

This is by design (trust boundary — we only relay for friends), but it limits the relay graph. If A→C are friends and B→C are friends, C can relay for A↔B. But if A wants to reach D through C, and D isn't C's friend, C refuses. This is fine for the current design but worth documenting as a known limitation.

### Issue 4 — BLE Device ID Rotation on iOS (LOW)

Dan's iPhone rotates BLE peripheral addresses, causing stale device IDs in `bleCentralDeviceId`/`blePeripheralDeviceId`. Sends to old IDs produce "Cannot send to disconnected device/central" errors. The dedup logic `_isDuplicatePeerByServiceUuid()` (ble_transport_service.dart:403-429) handles *new* connections, but stale IDs in the peer state linger until the next ANNOUNCE overwrites them. Mostly log noise since UDP works fine.

## Architecture Quick Reference

- **State:** Redux store (`AppState`). Key slices: `PeersState`, `TransportsState`, `MessagesState`, `FriendshipsState`, `SettingsState`
- **Peer lifecycle:** Discovered (BLE scan) → Connected (GATT) → Identified (ANNOUNCE with pubkey/signature) → Friend (explicit offer/accept)
- **Nearby panel reads:** `PeersState.nearbyBlePeers` — `peers.values.where((p) => p.isConnected && p.hasBleConnection)`
- **Reachability:** `PeerState.isReachable` = `hasBleConnection || udpAddress != null`
- **Transport preference:** BLE preferred over UDP when both available (`PeerState.activeTransport`)
- **Discovery loop:** `_discoverUnreachableFriends()` runs on every announce tick (30s), per-peer throttled at 60s
- **Signaling:** Friends-only. Well-connected friends relay signaling metadata (addresses, punch timing), never message content

## Key Files

| File | Purpose |
|------|---------|
| `lib/src/bitchat.dart` | Main coordinator — lifecycle, discovery loop, transport management |
| `lib/src/transport/ble_transport_service.dart` | BLE transport — scan, connect, send, disconnect |
| `lib/src/ble/ble_central_service.dart` | BLE central role — outbound connections |
| `lib/src/ble/ble_peripheral_service.dart` | BLE peripheral role — inbound connections, advertising |
| `lib/src/signaling/signaling_service.dart` | Signaling — address queries, hole-punch coordination |
| `lib/src/transport/hole_punch_service.dart` | UDP hole-punching — simultaneous punch packets |
| `lib/src/routing/message_router.dart` | Packet routing — ANNOUNCE handling, message dispatch |
| `lib/src/store/peers_state.dart` | Peer state model — `PeerState`, `DiscoveredPeerState` |
| `lib/src/store/peers_reducer.dart` | Peer state reducer — all peer state transitions |
| `lib/src/store/peers_actions.dart` | Redux actions for peer state changes |
| `lib/main.dart` | App entry — identity init, UI, message handling |

## Planned Feature — BLE Signaling Relay (next task)

**Scenario:** Dan switches from WiFi to cellular. Close and far stay on WiFi. Dan is in BLE range of close but not far. Currently, dan loses contact with far entirely because the signaling relay selection (`queryPeerAddress()` and `requestHolePunch()` in signaling_service.dart lines 92 and 142) filters candidates using `wellConnectedFriends` — which requires `isFriend && isWellConnected && isReachable`. Close is reachable (via BLE) and a friend, but not well-connected (behind WiFi NAT, no globally routable IP). So dan never asks close to relay.

**But close *can* relay:** Dan can send signaling to close over BLE. Close has far's address in its `addressTable` (registered from far's UDP ANNOUNCE on the same WiFi). Close can send PUNCH_INITIATE to both dan (over BLE) and far (over UDP). The plumbing works — the relay selection filter is too restrictive.

**Implementation plan:**

1. **Widen relay selection** in `SignalingService`: Replace `store.state.peers.wellConnectedFriends` with a new getter like `signalingCapableFriends` — any friend that is reachable via any transport (`isFriend && isReachable`), not just well-connected ones. This affects `queryPeerAddress()` (line 92) and `requestHolePunch()` (line 142).

2. **Address registration from BLE ANNOUNCEs:** `processAnnounceFromFriend()` (line 236) currently prefers `observedIp`/`observedPort` from the UDX connection. When an ANNOUNCE arrives over BLE, there's no observed address — it must use the `claimedAddress` from the ANNOUNCE payload. This already works as a fallback (`effectiveIp = observedIp ?? claimedIp`), but verify that BLE-received friend ANNOUNCEs actually call `processAnnounceFromFriend()` with the claimed address populated.

3. **`_handlePunchRequest()` on the relay side** (signaling_service.dart:356-403): Already transport-agnostic — it looks up addresses in `addressTable` and sends PUNCH_INITIATE via `sendSignaling` (which tries BLE first). No changes needed here.

4. **Consider renaming:** Update comments and log messages that say "well-connected friend" to reflect the broader relay eligibility. Keep `isWellConnected` as a property (still useful for distinguishing peers with public IPs) but don't gate signaling on it.

Key files to change:
- `lib/src/store/peers_state.dart` — add `signalingCapableFriends` getter
- `lib/src/signaling/signaling_service.dart` — replace `wellConnectedFriends` with `signalingCapableFriends` in `queryPeerAddress()` and `requestHolePunch()`
- `lib/src/bitchat.dart` — verify BLE ANNOUNCE path calls `processAnnounceFromFriend()` with claimed address

## iOS Identity Persistence Note

`flutter_secure_storage` stores the Ed25519 key pair in iOS Keychain, which **survives app uninstall/reinstall**. To reset identity on iOS, you must either delete the Keychain entry programmatically (`storage.delete(key: 'identity')`) or via Keychain Access on the Mac. App deletion alone is not enough.
