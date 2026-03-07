# Bitchat Transport Architecture

**Last updated**: 2026-02-12
**Branch**: `feat/remote_connection`
**Tests**: 294 passing

---

## Layer Overview

```
+---------------------------------------------------------------+
|                    Application Layer (GSG)                      |
|  main.dart — UI, user actions, message display                 |
+---------------------------------------------------------------+
        |                                           ^
        | send(), sendReadReceipt()                 | onMessageReceived
        | sendAnnounceToFriend()                    | onPeerConnected
        v                                           | onPeerDisconnected
+---------------------------------------------------------------+
|                   Coordinator (Bitchat)                         |
|  bitchat.dart — Orchestrates everything                        |
|  - Creates & signs ALL outgoing packets                        |
|  - Manages transport lifecycle & timers                        |
|  - Handles BLE fragmentation for large messages                |
|  - Wires transports → MessageRouter → application callbacks   |
+---------------------------------------------------------------+
        |                       |                       |
        v                       v                       v
+----------------+  +---------------------+  +------------------+
| ProtocolHandler|  |   MessageRouter      |  | FragmentHandler  |
| protocol_      |  |   message_router.dart|  | fragment_        |
| handler.dart   |  |                      |  | handler.dart     |
|                |  | - Signature verify   |  |                  |
| - Encode/decode|  | - Deduplication      |  | - Fragment large |
|   ANNOUNCE     |  | - ANNOUNCE → Redux   |  |   payloads       |
| - Create pkts  |  | - Message targeting  |  | - Reassemble     |
| - Sign/verify  |  | - Fragment reassembly|  |   incoming frags |
+----------------+  | - ACK dispatch       |  +------------------+
                     +---------------------+
        |                       |
        v                       v
+---------------------------------------------------------------+
|                    Redux Store (AppState)                       |
|  Single source of truth for all state                          |
|  - PeersState: discovered devices, identified peers            |
|  - MessagesState: message delivery tracking                    |
|  - FriendshipsState: friend relationships                      |
|  - SettingsState: transport enable/disable                     |
+---------------------------------------------------------------+
        ^                                           ^
        |                                           |
+---------------------------+   +---------------------------+
| BLE Transport Service     |   | LibP2P Transport Service  |
| ble_transport_service.dart|   | libp2p_transport_         |
|                           |   | service.dart              |
| - Central (scan/connect)  |   | - UDX transport over IPv6 |
| - Peripheral (advertise)  |   | - Noise security          |
| - Auto-connect on discover|   | - /gever/1.0.0 protocol   |
| - Deserialize → callback  |   | - Raw bytes → callback    |
+---------------------------+   +---------------------------+
        |           |                       |
        v           v                       v
+-------------+ +----------------+  +----------------+
| BLE Central | | BLE Peripheral |  | dart_libp2p    |
| Service     | | Service        |  | Host           |
| (scanner)   | | (advertiser)   |  | (P2P node)     |
+-------------+ +----------------+  +----------------+
        |           |                       |
        v           v                       v
   FlutterBluePlus  BlePeripheral      UDX/UDP sockets
   (native plugin)  (native plugin)    (IPv6 Internet)
```

---

## Wire Format: BitchatPacket

All communication across both transports uses a single binary format.

### Header (152 bytes, fixed)

```
Offset  Size  Field             Description
------  ----  -----             -----------
0       1     type              PacketType enum value
1       1     ttl               Time-to-live (reserved, set to 0)
2       4     timestamp         Unix seconds, big-endian
6       32    senderPubkey      Ed25519 public key of sender
38      32    recipientPubkey   Ed25519 public key of recipient (zeros = broadcast)
70      2     payloadLength     Big-endian uint16
72      16    packetId          UUID v4 bytes (for deduplication)
88      64    signature         Ed25519 signature over header+payload (with sig zeroed)
------
152 total header bytes
```

### Payload (variable length, follows header)

Content depends on packet type. See "Packet Types" below.

### Packet Types

| Value | Name              | Payload Contents                              |
|-------|-------------------|-----------------------------------------------|
| 0x01  | `announce`        | ANNOUNCE payload (see below)                  |
| 0x02  | `message`         | Application data (GSG blocks)                 |
| 0x03  | `fragmentStart`   | messageId(36) + totalFrags(2) + totalSize(4) + chunk |
| 0x04  | `fragmentContinue`| messageId(36) + fragIndex(2) + chunk          |
| 0x05  | `fragmentEnd`     | messageId(36) + fragIndex(2) + chunk          |
| 0x06  | `ack`             | UTF-8 message ID string                       |
| 0x07  | `nack`            | (unused)                                      |
| 0x08  | `readReceipt`     | UTF-8 message ID string                       |

### ANNOUNCE Payload Format

```
Offset  Size      Field
------  ----      -----
0       32        publicKey (Ed25519)
32      2         protocolVersion (big-endian, currently 1)
34      1         nicknameLength
35      N         nickname (UTF-8, N = nicknameLength)
35+N    2         addressLength (big-endian)
37+N    M         libp2pAddress (UTF-8, M = addressLength, optional)
```

### Signature Scheme

Every packet is Ed25519-signed before sending. The signing process:

1. Compute `getSignableBytes()` — full serialized packet with signature field zeroed
2. Sign with sender's Ed25519 private key
3. Write 64-byte signature into the signature field

Verification on receive:

1. Extract sender's public key from header
2. Compute `getSignableBytes()` — same zeroed-signature form
3. Verify signature against sender's public key
4. **Drop packet immediately if verification fails**

**Key files**: [protocol_handler.dart](lib/src/protocol/protocol_handler.dart) (`signPacket`, `verifyPacket`), [packet.dart](lib/src/models/packet.dart) (`getSignableBytes`, `serialize`, `deserialize`)

---

## Coordinator: Bitchat (bitchat.dart)

The `Bitchat` class is the central orchestrator. It owns all packet creation and signing.

### Responsibilities

1. **Transport lifecycle** — initialize, start, stop, dispose BLE and libp2p services
2. **Packet creation** — all `BitchatPacket` objects are created here (or via `ProtocolHandler`)
3. **Packet signing** — all packets are signed via `_protocolHandler.signPacket()` before sending
4. **Callback wiring** — connects transport callbacks → `MessageRouter` → application callbacks
5. **Timers** — periodic ANNOUNCE broadcast and BLE scanning
6. **Fragmentation** — coordinator handles BLE fragmentation for large messages
7. **Settings** — listens to Redux `SettingsState` to enable/disable transports at runtime

### Wiring Pattern

```dart
// Transport → Router (in _setupBleServiceCallbacks)
_bleService!.onBlePacketReceived = (packet, {bleDeviceId, rssi}) {
  _messageRouter.processPacket(packet,
    transport: PeerTransport.bleDirect,
    bleDeviceId: bleDeviceId, rssi: rssi);
};

// Transport → Router (in _setupLibp2pServiceCallbacks)
_libp2pService!.onLibp2pDataReceived = (peerId, data) {
  final packet = BitchatPacket.deserialize(data);
  _messageRouter.processPacket(packet,
    transport: PeerTransport.libp2p,
    libp2pPeerId: peerId);
};

// Router → Application (in _setupRouterCallbacks)
_messageRouter.onMessageReceived = (id, sender, payload) { ... };
_messageRouter.onAckReceived = (messageId) { ... };
_messageRouter.onReadReceiptReceived = (messageId) { ... };
_messageRouter.onPeerAnnounced = (data, transport, {isNew}) { ... };
_messageRouter.onAckRequested = (transport, peerId, messageId) { ... };
```

### Timers

| Timer | Default Interval | Action |
|-------|-----------------|--------|
| Announce | 10 seconds | Broadcast ANNOUNCE via BLE + libp2p |
| Scan | 10 seconds | BLE scan for new devices |
| Stale cleanup | On each announce tick | Remove peers not seen in 2x announce interval |

---

## Message Router (message_router.dart)

Single entry point for all incoming packets from both transports.

### `processPacket()` Flow

```
processPacket(packet, transport, bleDeviceId?, libp2pPeerId?, rssi)
    │
    ├── 1. Verify signature (Ed25519)
    │       └── FAIL → drop packet, return
    │
    ├── 2. Is ANNOUNCE? → _handleAnnounce() (always, bypass dedup)
    │       ├── Decode payload (pubkey, nickname, version, address)
    │       ├── Dispatch PeerAnnounceReceivedAction to Redux
    │       ├── Associate bleDeviceId or libp2pPeerId
    │       └── Call onPeerAnnounced callback
    │
    ├── 3. Deduplication check (BloomFilter on packetId)
    │       └── Already seen → drop packet, return
    │
    └── 4. Route by type:
            ├── MESSAGE → _handleMessage()
            │     ├── Check _isForUs (recipient matches or broadcast)
            │     ├── Call onMessageReceived
            │     └── If libp2p: call onAckRequested
            │
            ├── FRAGMENT_START/CONTINUE/END → _handleFragment()
            │     ├── Delegate to FragmentHandler.processFragment()
            │     └── If reassembly complete → call onMessageReceived
            │
            ├── ACK → call onAckReceived
            │
            └── READ_RECEIPT → call onReadReceiptReceived
```

**Key file**: [message_router.dart](lib/src/routing/message_router.dart)

---

## BLE Transport

### Overview

Each device simultaneously runs:
- **Central mode** (scanner): discovers and connects to other devices
- **Peripheral mode** (advertiser): accepts incoming connections

### Classes

| Class | File | Role |
|-------|------|------|
| `BleTransportService` | [ble_transport_service.dart](lib/src/transport/ble_transport_service.dart) | Coordinates Central + Peripheral, implements `TransportService` |
| `BleCentralService` | [ble_central_service.dart](lib/src/ble/ble_central_service.dart) | Scans, connects, reads/writes as GATT client |
| `BlePeripheralService` | [ble_peripheral_service.dart](lib/src/ble/ble_peripheral_service.dart) | Advertises, accepts connections, reads/writes as GATT server |

### BLE Peer Discovery

```
1. SCAN
   BleCentralService.startScan()
     → FlutterBluePlus.startScan(androidScanMode: lowLatency)
     → _onScanResults() filters devices with service UUIDs
     → Calls onDeviceDiscovered callback

2. AUTO-CONNECT
   BleTransportService._onDeviceDiscovered()
     → Dispatches BleDeviceDiscoveredAction to Redux
     → If new device: _autoConnectToPeer(deviceId)
       → Dispatches BleDeviceConnectingAction
       → BleCentralService.connectToDevice(deviceId)

3. GATT SERVICE DISCOVERY
   BleCentralService.connectToDevice()
     → device.connect(timeout: 15s)
     → device.discoverServices()
     → Find service matching our UUID
     → Find characteristic 0000ff01-...
     → characteristic.setNotifyValue(true)  ← enables data reception
     → NOT a Bitchat peer? → disconnect

4. ANNOUNCE EXCHANGE (triggered by coordinator)
   Bitchat._setupBleServiceCallbacks()
     → On connection event: _broadcastAnnounce()
     → Creates ANNOUNCE packet, signs it, broadcasts via BLE
     → Remote peer's router processes ANNOUNCE → peer identified
```

### BLE Service UUID

Each device advertises a **unique** service UUID derived from its Ed25519 public key:

```dart
// identity.dart
String get bleServiceUuid {
  final uuidBytes = publicKey.sublist(16, 32);  // last 128 bits
  // Format as UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
}
```

Scanning is broad (all service UUIDs). Filtering happens after GATT service discovery confirms the Bitchat characteristic exists.

### BLE Data Exchange

**Characteristic UUID** (fixed for all devices): `0000ff01-0000-1000-8000-00805f9b34fb`

| Direction | Central (scanner) | Peripheral (advertiser) |
|-----------|-------------------|------------------------|
| **Send** | `characteristic.write(data, withoutResponse: true)` | `BlePeripheral.updateCharacteristic(data, deviceId)` |
| **Receive** | `characteristic.onValueReceived` stream | `_onWriteRequest` callback |

**Send path** (`BleTransportService.sendToPeer`):
1. Try central first (we connected to them)
2. Fall back to peripheral (they connected to us)

### BLE ANNOUNCE Flow

```
Coordinator                     BLE Transport                Router
    |                               |                          |
    |-- _broadcastAnnounce() ------>|                          |
    |   create ANNOUNCE packet      |                          |
    |   sign with Ed25519           |                          |
    |   serialize to bytes          |                          |
    |   bleService.broadcast(bytes) |                          |
    |                               |-- write to all           |
    |                               |   connected devices      |
    |                               |                          |
    |                               |<-- onValueReceived ------|
    |                               |   (from remote peer)     |
    |                               |                          |
    |                               |-- deserialize packet     |
    |                               |-- onBlePacketReceived -->|
    |                               |                          |
    |                               |               processPacket()
    |                               |               verify signature
    |                               |               decode ANNOUNCE
    |                               |               dispatch to Redux
    |<---------- onPeerAnnounced ---|---------------|
```

### BLE Message Flow

```
Coordinator                     BLE Transport                Router
    |                               |                          |
    |-- send(recipientPubkey, data) |                          |
    |   create MESSAGE packet       |                          |
    |   payload < 360 bytes?        |                          |
    |   YES: sign, serialize        |                          |
    |        sendToPeer(deviceId,   |                          |
    |                   bytes)      |                          |
    |   NO:  fragment payload       |                          |
    |        sign each fragment     |                          |
    |        send fragments with    |                          |
    |        20ms delay between     |                          |
    |                               |                          |
    |                               |<-- data from remote -----|
    |                               |-- deserialize packet     |
    |                               |-- onBlePacketReceived -->|
    |                               |                          |
    |                               |               processPacket()
    |                               |               verify signature
    |                               |               check recipient
    |                               |               (fragment? reassemble)
    |<---------- onMessageReceived -|---------------|
```

### BLE Fragmentation

Handled at the **coordinator** level, not in the transport.

| Parameter | Value | Derivation |
|-----------|-------|------------|
| BLE MTU | 512 bytes | Platform default |
| Packet header | 152 bytes | Fixed |
| Fragment threshold | 360 bytes | MTU - header |
| Chunk size | 300 bytes | Conservative fit with fragment metadata |
| Inter-fragment delay | 20ms | Avoid BLE buffer overflow |
| Reassembly timeout | 30 seconds | Cleanup timer |

**Coordinator creates fragments** (`_sendFragmentedViaBle`):
```dart
final fragmented = _fragmentHandler.fragment(
  payload: payload,
  senderPubkey: identity.publicKey,
  recipientPubkey: recipientPubkey,
);
for (final fragment in fragmented.fragments) {
  await _protocolHandler.signPacket(fragment);  // sign each fragment
  await _bleService!.sendToPeer(bleDeviceId, fragment.serialize());
  await Future.delayed(FragmentHandler.fragmentDelay);  // 20ms
}
```

**Router reassembles** (via `FragmentHandler.processFragment`):
- `fragmentStart` → create reassembly state, store first chunk
- `fragmentContinue` → add chunk by index
- `fragmentEnd` → add final chunk, attempt reassembly
- When all chunks received → concatenate in order → deliver as complete message

**Key files**: [fragment_handler.dart](lib/src/protocol/fragment_handler.dart), [bitchat.dart](lib/src/bitchat.dart) (`_sendFragmentedViaBle`, `_broadcastFragmentedViaBle`)

### BLE Constants

| Constant | Value | Location |
|----------|-------|----------|
| Characteristic UUID | `0000ff01-0000-1000-8000-00805f9b34fb` | `ble_central_service.dart`, `ble_peripheral_service.dart` |
| Scan timeout | 10 seconds | `ble_central_service.dart` |
| Connection timeout | 15 seconds | `ble_central_service.dart` |
| Max characteristic size | 512 bytes | `ble_peripheral_service.dart` |

---

## LibP2P Transport

### Overview

Internet-based P2P transport using `dart_libp2p` with UDX (UDP-based) transport over IPv6 and Noise security protocol.

### Classes

| Class | File | Role |
|-------|------|------|
| `LibP2PTransportService` | [libp2p_transport_service.dart](lib/src/transport/libp2p_transport_service.dart) | Manages libp2p `Host`, implements `TransportService` |
| `Host` | `dart_libp2p` | Libp2p node with peer routing, stream multiplexing |

### LibP2P Host Setup

```dart
// createHost() in libp2p_transport_service.dart
final keyPair = await crypto_ed25519.generateEd25519KeyPair();
final options = [
  Libp2p.identity(keyPair),
  Libp2p.connManager(ConnectionManager()),
  Libp2p.transport(UDXTransport(...)),        // UDP-based transport
  Libp2p.security(await NoiseSecurity.create(keyPair)),  // Noise protocol
  Libp2p.listenAddrs([MultiAddr('/ip6/::/udp/0/udx')]),  // IPv6, random port
];
final host = await Libp2p.new_(options);
host.setStreamHandler('/gever/1.0.0', _handleGeverRequest);
await host.start();
```

**Identity**: Each host gets a new Ed25519 keypair (separate from the Bitchat identity). The host is identified by its `PeerId` (derived from the libp2p keypair).

**Public IPv6**: Fetched from `https://ipv6.icanhazip.com/` at startup, used for external connectivity.

### LibP2P Peer Discovery

LibP2P peers are discovered through ANNOUNCE exchange, not through libp2p's built-in discovery:

1. Peer A sends ANNOUNCE via BLE or libp2p (e.g., through a friend request)
2. ANNOUNCE payload includes `libp2pAddress` (multiaddr string)
3. Receiver stores address in Redux (`PeerState.libp2pAddress`)
4. When sending, coordinator looks up `peer.libp2pHostId` from Redux

### LibP2P Connection

```dart
// connectToHost() — used when accepting friend requests
Future<String?> connectToHost({required String hostId, required List<String> hostAddrs}) {
  // Try IPv4 addresses first (more common), then IPv6
  for (final addr in orderedAddrs) {
    final peerId = PeerId.fromString(hostId);
    final addrInfo = AddrInfo(peerId, [MultiAddr(addr)]);
    await _host!.connect(addrInfo);
    return addr;  // return successful address
  }
  return null;  // all addresses failed
}
```

**Peerstore**: Before dialing, addresses are added to the libp2p peerstore:
```dart
await _host!.peerStore.addrBook.addAddrs(peerId, multiAddrs, Duration(hours: 1));
```

### LibP2P Data Exchange

**Custom protocol**: `/gever/1.0.0`

**Send** (`sendToPeer`):
```dart
final ctx = Context(timeout: Duration(seconds: 10));
P2PStream stream = await _host!.newStream(
  PeerId.fromString(peerId), ['/gever/1.0.0'], ctx);
await stream.write(data);
await stream.close();
```

**Receive** (stream handler):
```dart
Future<void> _handleGeverRequest(P2PStream stream, PeerId remotePeer) async {
  final data = await stream.read();
  if (data.isNotEmpty) {
    onDataReceived(remotePeer.toBase58(), Uint8List.fromList(data));
  }
  await stream.close();
}
```

### LibP2P ANNOUNCE Flow

```
Coordinator                     LibP2P Transport             Router
    |                               |                          |
    |-- _broadcastAnnounceViaLibp2p |                          |
    |   create ANNOUNCE packet      |                          |
    |   include our libp2p address  |                          |
    |   sign with Ed25519           |                          |
    |   serialize to bytes          |                          |
    |   libp2pService.broadcast()   |                          |
    |                               |-- for each libp2p peer:  |
    |                               |   newStream(/gever/1.0.0)|
    |                               |   write(bytes)           |
    |                               |   close stream           |
    |                               |                          |
    |                               |<-- _handleGeverRequest---|
    |                               |   (from remote peer)     |
    |                               |                          |
    |                               |-- onLibp2pDataReceived ->|
    |                               |   (raw bytes)            |
    |                          Coordinator deserializes:        |
    |                          BitchatPacket.deserialize(data)  |
    |                               |                          |
    |                               |-------processPacket() -->|
    |                               |                          |
    |                               |               verify signature
    |                               |               decode ANNOUNCE
    |                               |               dispatch to Redux
    |<---------- onPeerAnnounced ---|---------------|
```

### LibP2P Message Flow

```
Coordinator                     LibP2P Transport             Router
    |                               |                          |
    |-- send(recipientPubkey, data) |                          |
    |   create MESSAGE packet       |                          |
    |   sign with Ed25519           |                          |
    |   serialize to bytes          |                          |
    |   libp2pService.sendToPeer()  |                          |
    |                               |-- newStream to peer      |
    |                               |   write serialized bytes |
    |                               |   close stream           |
    |                               |                          |
    |                               |<-- _handleGeverRequest---|
    |                               |-- onLibp2pDataReceived ->|
    |                          Coordinator deserializes:        |
    |                          BitchatPacket.deserialize(data)  |
    |                               |-- processPacket() ------>|
    |                               |               verify signature
    |                               |               check recipient
    |                               |               onAckRequested →
    |<-- send ACK back -------------|<--------------|
    |   create ACK packet           |                          |
    |   sign, serialize             |                          |
    |   sendToPeer(ackBytes)        |                          |
    |                               |                          |
    |<---------- onMessageReceived -|---------------|
```

**Note**: LibP2P messages trigger an ACK response. The router calls `onAckRequested`, and the coordinator creates, signs, and sends an ACK packet back to the sender. BLE does not use ACKs (write-with-response at the BLE level confirms delivery).

### LibP2P Constants

| Constant | Value |
|----------|-------|
| Protocol ID | `/gever/1.0.0` |
| Send timeout | 10 seconds |
| Listen address | `/ip6/::/udp/0/udx` |
| Peerstore TTL | 1 hour |

---

## Transport Selection

When sending a message, the coordinator selects a transport:

```
1. BLE preferred if:
   - BLE enabled in settings
   - BLE transport available
   - Peer has bleDeviceId (connected via BLE)

2. LibP2P fallback if:
   - LibP2P enabled in settings
   - LibP2P transport available
   - Peer has libp2pHostId

3. BLE send fails → try libp2p fallback (if available)

4. No transport available → return null (peer offline)
```

The coordinator also supports **read receipts** and **broadcasts** with the same priority logic (BLE first, libp2p fallback).

---

## Redux State

### AppState Structure

```
AppState
  ├── peers: PeersState
  │     ├── discoveredBlePeers: Map<deviceId, DiscoveredPeerState>
  │     │     Pre-ANNOUNCE BLE devices (found by scan, not yet identified)
  │     ├── discoveredLibp2pPeers: Map<peerId, DiscoveredPeerState>
  │     │     Pre-ANNOUNCE libp2p peers
  │     └── peers: Map<pubkeyHex, PeerState>
  │           Post-ANNOUNCE identified peers with full identity
  │
  ├── messages: MessagesState
  │     └── messages: Map<messageId, MessageState>
  │           Tracks sending → sent → delivered → read status
  │
  ├── friendships: FriendshipsState
  │     └── friendships: Map<pubkeyHex, FriendshipState>
  │
  └── settings: SettingsState
        ├── bluetoothEnabled: bool
        └── libp2pEnabled: bool
```

### Peer Lifecycle in Redux

```
BLE Scan finds device
  → BleDeviceDiscoveredAction → discoveredBlePeers[deviceId] created

Auto-connect initiated
  → BleDeviceConnectingAction → discoveredBlePeers[deviceId].isConnecting = true

BLE connection established
  → BleDeviceConnectedAction → discoveredBlePeers[deviceId].isConnected = true

ANNOUNCE received (identity known)
  → PeerAnnounceReceivedAction → peers[pubkeyHex] created/updated
                                 with nickname, transport, rssi, bleDeviceId, libp2pAddress

BLE disconnection
  → BleDeviceDisconnectedAction → discoveredBlePeers[deviceId].isConnected = false
  → PeerBleDisconnectedAction → peers[pubkeyHex].bleDeviceId = null

Stale cleanup (every 2x announce interval)
  → StaleDiscoveredBlePeersRemovedAction → remove old discoveredBlePeers
  → StalePeersRemovedAction → remove old peers
```

**Key files**: [peers_state.dart](lib/src/store/peers_state.dart), [peers_actions.dart](lib/src/store/peers_actions.dart), [peers_reducer.dart](lib/src/store/peers_reducer.dart)

---

## Identity

### BitchatIdentity

```dart
class BitchatIdentity {
  Uint8List publicKey;      // 32 bytes, Ed25519
  Uint8List privateKey;     // 64 bytes (seed + pubkey)
  SimpleKeyPair keyPair;    // For cryptography package
  String nickname;          // Mutable display name

  String get bleServiceUuid;      // Last 128 bits of publicKey → UUID format
  String get shortFingerprint;    // First 8 bytes, colon-separated hex
}
```

The BLE service UUID is derived deterministically from the public key, creating a cryptographic binding between BLE identity and the Ed25519 identity.

**Key file**: [identity.dart](lib/src/models/identity.dart)

---

## Design Principles

### No Store-and-Forward

Messages to offline peers **fail immediately**. The sender must retry later. No caching, no queuing, no relaying through intermediate peers. The application layer (GSG) handles persistence and retry.

### No Mesh / No Relaying

Messages go **directly** from sender to recipient. No multi-hop routing, no forwarding on behalf of other peers. The TTL field exists in the packet header but is unused (reserved for potential future mesh).

### Coordinator Owns Packet Creation

Transport services are thin byte-level I/O layers. They never create `BitchatPacket` objects or handle signing. All packet construction and Ed25519 signing happens in the coordinator (`Bitchat`).

### Unified Packet Format

Both BLE and libp2p use the same `BitchatPacket` binary format. The `MessageRouter` has a single `processPacket()` entry point that handles both transports identically (with transport-specific metadata passed as parameters).

---

## Test Coverage

**294 tests** across 12 test files:

| Test File | Description |
|-----------|-------------|
| `test/routing/message_router_test.dart` | Router: signature verification, ANNOUNCE/MESSAGE/ACK/fragment handling, dedup |
| `test/integration/protocol_router_integration_test.dart` | End-to-end: Alice↔Bob ANNOUNCE + MESSAGE + ACK + READ_RECEIPT via both transports |
| `test/protocol/protocol_handler_test.dart` | ANNOUNCE encode/decode, sign/verify, tamper detection, round-trip |
| `test/protocol/fragment_handler_test.dart` | Fragment/reassemble, edge cases, timeout cleanup |
| `test/store/peers_reducer_test.dart` | PeersState actions and reducer logic |
| `test/store/messages_reducer_test.dart` | MessagesState delivery tracking |
| `test/store/friendships_reducer_test.dart` | FriendshipsState management |
| `test/store/settings_reducer_test.dart` | SettingsState transport toggle |
| `test/store/root_reducer_test.dart` | Root reducer action routing |
| `test/store/persistence_service_test.dart` | SharedPreferences persistence + migration |
| `test/models/identity_test.dart` | Identity creation, UUID derivation |
| `test/bitchat_test.dart` | BitchatPacket serialization |

```bash
# Run all tests
flutter test

# Analyze for issues
dart analyze lib/src/ test/
```
