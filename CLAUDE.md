# Claude Instructions for Bitchat Transport
## CRITICAL: always be precise, critical, but helpful. Prefer to ask rather than assume if you have unclarities
## CRITICAL: NO Legacy or Compatibility Code

**IMPORTANT**: When refactoring, DO NOT keep old code "for legacy" or "for compatibility".

- ❌ **NO** `// Legacy - kept for compatibility` comments
- ❌ **NO** keeping both old and new implementations
- ✅ **DO** fully replace old code with new implementation
- ✅ **DO** remove unused imports and dead code
- ✅ **DO** update all call sites when changing APIs
- ❌ **NO** `PeerStore` - use Redux store (`AppState.peers`) only

---

## CRITICAL: NO Store-and-Forward / NO Relaying

**IMPORTANT**: Bitchat does NOT implement store-and-forward or message relaying.

- ❌ **NO caching** messages for offline peers
- ❌ **NO relaying** messages through intermediate peers
- ❌ **NO forwarding** packets on behalf of other peers

Messages are sent **directly** to the recipient:
- If the recipient is **online and reachable** → message is delivered
- If the recipient is **offline** → message **fails** and sender must retry later

This is by design - the application layer (GSG) handles message persistence and retry logic.

---

## Critical: always be precise, critical, but helpful.

## CRITICAL: NO Legacy or Compatibility Code — EVER

**IMPORTANT**: NEVER write backward-compatible code, migration shims, or compatibility layers. This applies to ALL code changes including protocol changes, API changes, data format changes, and refactors.

- ❌ **NO** `// Legacy - kept for compatibility` comments
- ❌ **NO** keeping both old and new implementations
- ❌ **NO** backward-compatible encoding/decoding (e.g., "old receivers will still parse this")
- ❌ **NO** migration paths or version-gated behavior
- ❌ **NO** fallback logic for old formats or protocols
- ✅ **DO** fully replace old code with new implementation
- ✅ **DO** remove unused imports and dead code
- ✅ **DO** update all call sites when changing APIs
- ✅ **DO** change protocols/formats cleanly without worrying about old versions
- ❌ **NO** `PeerStore` - use Redux store (`AppState.peers`) only

---

## CRITICAL: NO Store-and-Forward / NO Relaying

**IMPORTANT**: Bitchat does NOT implement store-and-forward or message relaying.

- ❌ **NO caching** messages for offline peers
- ❌ **NO relaying** messages through intermediate peers
- ❌ **NO forwarding** packets on behalf of other peers

Messages are sent **directly** to the recipient:
- If the recipient is **online and reachable** → message is delivered
- If the recipient is **offline** → message **fails** and sender must retry later

This is by design - the application layer (GSG) handles message persistence and retry logic.

---

## BLE Service UUID Architecture

**IMPORTANT**: Each device advertises a **unique** BLE service UUID composed of two parts:
- **First 8 bytes**: Static Grassroots identifier (`84c40316-0871-e5ad`) — first 8 bytes of SHA-256("grassroots")
- **Last 8 bytes**: Last 8 bytes of the device's Ed25519 public key

This allows identifying Grassroots devices **before connecting** by checking the advertised UUID prefix.

### How It Works

1. **Advertising (Peripheral Mode)**:
   - Each device advertises with UUID = `grassroots_prefix + last_64_bits(publicKey)`
   - The prefix `84c40316-0871-e5ad` identifies the device as a Grassroots peer

2. **Scanning (Central Mode)**:
   - Devices scan for all BLE devices advertising service UUIDs
   - **Filter by Grassroots prefix**: only process devices whose UUID starts with `84c403160871e5ad`
   - Non-Grassroots devices (headphones, smartwatches) are skipped immediately

3. **Connection & Service Discovery**:
   - Connect to Grassroots-prefixed devices
   - Perform GATT service discovery as defense-in-depth
   - Check for Bitchat characteristic (UUID: `0000ff01-0000-1000-8000-00805f9b34fb`)
   - If characteristic NOT found → disconnect (spoofed prefix or corrupt device)
   - If characteristic found → proceed to ANNOUNCE exchange

4. **ANNOUNCE Exchange & Verification**:
   - After service discovery confirms Bitchat peer, exchange ANNOUNCE packets
   - ANNOUNCE contains: full public key, nickname, signature
   - Receiving device verifies the signature and stores the mapping: `BLE_Device_ID -> PublicKey`

5. **Identity Mapping**:
   - BLE layer knows devices by MAC address / device ID
   - Application layer (GSG) knows peers by Ed25519 public key
   - Bitchat maintains the mapping between these identities

### DO NOT:
- ❌ Use a single fixed service UUID for all devices
- ❌ Skip the Grassroots prefix filter during scanning
- ❌ Assume UUID prefix match means peer is verified (ANNOUNCE still required)

### DO:
- ✅ Derive UUID from Grassroots prefix + last 8 bytes of public key
- ✅ Filter scan results by Grassroots UUID prefix
- ✅ Keep GATT characteristic check as defense-in-depth after connection
- ✅ Exchange ANNOUNCE packets after confirming Bitchat peer
- ✅ Maintain BLE Device ID ↔ Public Key mapping

## NO Store-and-Forward

**IMPORTANT**: Bitchat does NOT implement store-and-forward messaging.

- Messages to offline peers simply **fail** - they are NOT cached
- The sender must retry later when the peer is online
- This is by design to keep the protocol simple and avoid message accumulation
- If a peer is unreachable via any enabled transport (BLE or libp2p), `send()` returns `false`

### DO NOT:
- ❌ Cache messages for offline peers
- ❌ Implement store-and-forward queues
- ❌ Automatically retry sending to offline peers
- ❌ Hold messages in memory waiting for peers to reconnect

### DO:
- ✅ Return `false` immediately if peer is unreachable
- ✅ Let the application layer handle retry logic if needed
- ✅ Try all available transports (BLE first, then libp2p) before failing

## Redux Architecture for Peers

All peer state is managed through Redux:

### State Structure
- `AppState.peers` → `PeersState`
  - `discoveredBlePeers: Map<String, DiscoveredPeerState>` - Pre-ANNOUNCE BLE devices
  - `peers: Map<String, PeerState>` - Post-ANNOUNCE identified peers

### Key Actions
- `BleDeviceDiscoveredAction` - BLE scan found a device
- `BleDeviceConnectedAction` / `BleDeviceDisconnectedAction` - Connection state
- `PeerAnnounceReceivedAction` - ANNOUNCE packet received (peer identified)
- `PeerRssiUpdatedAction` - Signal strength updated
- `StaleDiscoveredBlePeersRemovedAction` / `StalePeersRemovedAction` - Cleanup

### UI Pattern
```dart
// Read peers from Redux store
Map<String, Peer> get _peers {
  return {
    for (var p in appStore.state.peers.connectedPeers) 
      p.pubkeyHex: _peerStateToLegacy(p)
  };
}

// Subscribe to store changes
appStore.onChange.listen((_) => setState(() {}));
```

## Transport Layer Settings

### Transport Priority
When both transports are enabled and a peer is reachable via both:
1. **Bluetooth (BLE)** is preferred - faster, no Internet needed, works for nearby peers
2. **libp2p (Internet)** is fallback - works globally but requires Internet

### Disabling Transports
- When Bluetooth is disabled: stop advertising, stop scanning, no BLE communication
- When libp2p is disabled: stop libp2p host, no Internet communication
- At least one transport should remain enabled for the app to function

### Per-Peer Addresses
Each peer can have both a BLE address and a libp2p address stored:
- `PeerState.bleDeviceId` - BLE device ID (MAC on Android, UUID on iOS)
- `PeerState.libp2pAddress` - libp2p multiaddress
- Messages route through the best available transport based on peer availability

## Code References

- Service UUID derivation: `lib/src/models/identity.dart` → `deriveServiceUuid()` static method, `bleServiceUuid` getter
- Grassroots UUID prefix: `lib/src/models/identity.dart` → `BitchatIdentity.grassrootsUuidPrefix`
- Scan prefix filtering: `lib/src/ble/ble_central_service.dart` → `_onScanResults()`
- Peripheral advertising: `lib/src/ble/ble_peripheral_service.dart` → `startAdvertising()`
- Central scanning: `lib/src/ble/ble_central_service.dart` → `startScan()` and `_onScanResults()`
- ANNOUNCE handling: `lib/src/transport/ble_transport_service.dart` → `_handleAnnounce()`
- Redux store: `lib/src/store/` → `peers_state.dart`, `peers_actions.dart`, `peers_reducer.dart`
