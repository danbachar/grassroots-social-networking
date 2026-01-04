# Claude Instructions for Bitchat Transport

## BLE Service UUID Architecture

**IMPORTANT**: Each Bitchat device MUST advertise its own **unique** service UUID derived from its public key.

### Why Unique UUIDs?

1. **Identity**: The service UUID is derived from the device's Ed25519 public key (last 128 bits)
2. **Security**: Provides cryptographic binding between BLE identity and cryptographic identity
3. **Discovery**: Devices scan broadly and discover ALL devices with service UUIDs
4. **Verification**: After connection, devices exchange ANNOUNCE packets containing full public keys and verify identity

### How It Works

1. **Advertising (Peripheral Mode)**:
   - Each device advertises with UUID = `last_128_bits(publicKey)`
   - Example: Device A with pubkey `0x1234...` advertises UUID `12345678-9abc-def0-1234-567890abcdef`

2. **Scanning (Central Mode)**:
   - Devices scan for ALL devices advertising ANY service UUID
   - Do NOT filter by specific UUID during scan
   - The scan is opportunistic - we discover any device that might be a peer

3. **Connection & Service Discovery**:
   - After BLE connection established, perform GATT service discovery
   - Check if device has the Bitchat GATT characteristic (UUID: `0000ff01-0000-1000-8000-00805f9b34fb`)
   - If characteristic NOT found → disconnect (not a Bitchat peer, e.g., headphones)
   - If characteristic found → it's a Bitchat peer, proceed to step 4
   
   **IMPORTANT**: We cannot know if a device is a Bitchat peer until AFTER connection and service discovery.
   This is why we connect to all devices and disconnect from non-peers after discovery.

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
- ❌ Filter scans to only look for specific UUIDs during discovery
- ❌ Assume a device is a Bitchat peer before service discovery
- ❌ Assume UUID uniqueness means peer uniqueness (verify via ANNOUNCE)

### DO:
- ✅ Derive unique service UUID from each device's public key
- ✅ Scan broadly for all devices with service UUIDs
- ✅ Connect to devices, then perform service discovery to check for Bitchat characteristic
- ✅ Disconnect from non-Bitchat devices after service discovery
- ✅ Exchange ANNOUNCE packets after confirming Bitchat peer
- ✅ Maintain BLE Device ID ↔ Public Key mapping

## Code References

- Service UUID derivation: `lib/src/models/identity.dart` → `bleServiceUuid` getter
- Peripheral advertising: `lib/src/ble/ble_peripheral_service.dart` → `startAdvertising()`
- Central scanning: `lib/src/ble/ble_central_service.dart` → `startScan()` and `_onScanResults()`
- ANNOUNCE handling: `lib/src/mesh/mesh_router.dart` → `handleAnnounce()`
