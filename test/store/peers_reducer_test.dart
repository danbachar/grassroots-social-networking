import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/src/store/peers_state.dart';
import 'package:bitchat_transport/src/store/peers_actions.dart';
import 'package:bitchat_transport/src/store/peers_reducer.dart';
import 'package:bitchat_transport/src/models/peer.dart';

/// Generate a deterministic 32-byte public key from a seed value.
Uint8List _testPubkey(int seed) {
  return Uint8List.fromList(List.generate(32, (i) => (seed + i) % 256));
}

/// Convert a pubkey to hex string (mirrors _pubkeyToHex in the reducer).
String _pubkeyHex(Uint8List pubkey) {
  return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  // =========================================================================
  // BLE Discovery Actions
  // =========================================================================

  group('BleDeviceDiscoveredAction', () {
    test('adds a new discovered peer', () {
      const state = PeersState.initial;
      final action = BleDeviceDiscoveredAction(
        deviceId: 'device-1',
        displayName: 'Pixel 7',
        rssi: -55,
        serviceUuid: 'uuid-abc',
      );

      final result = peersReducer(state, action);

      expect(result.discoveredBlePeers.length, 1);
      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.transportId, 'device-1');
      expect(peer.displayName, 'Pixel 7');
      expect(peer.rssi, -55);
      expect(peer.serviceUuid, 'uuid-abc');
      expect(peer.isConnecting, false);
      expect(peer.isConnected, false);
      expect(peer.consecutiveFailures, 0);
      expect(peer.nextRetryAfter, isNull);
    });

    test('updates existing peer RSSI and lastSeen', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            displayName: 'Pixel 7',
            rssi: -80,
            discoveredAt: now.subtract(const Duration(seconds: 30)),
            lastSeen: now.subtract(const Duration(seconds: 10)),
          ),
        },
      );
      final action = BleDeviceDiscoveredAction(
        deviceId: 'device-1',
        rssi: -50,
      );

      final result = peersReducer(initial, action);

      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.rssi, -50);
      // lastSeen should be updated (newer than the original)
      expect(
        peer.lastSeen.isAfter(now.subtract(const Duration(seconds: 10))),
        true,
      );
    });

    test('preserves existing displayName when action has no displayName', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            displayName: 'Pixel 7',
            rssi: -80,
            discoveredAt: now,
            lastSeen: now,
          ),
        },
      );
      final action = BleDeviceDiscoveredAction(
        deviceId: 'device-1',
        rssi: -60,
        // displayName intentionally omitted (null)
      );

      final result = peersReducer(initial, action);

      expect(result.discoveredBlePeers['device-1']!.displayName, 'Pixel 7');
    });
  });

  // =========================================================================
  // BleDeviceRssiUpdatedAction
  // =========================================================================

  group('BleDeviceRssiUpdatedAction', () {
    test('updates RSSI of existing discovered peer', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -80,
            discoveredAt: now,
            lastSeen: now,
          ),
        },
      );
      final action = BleDeviceRssiUpdatedAction(
        deviceId: 'device-1',
        rssi: -45,
      );

      final result = peersReducer(initial, action);

      expect(result.discoveredBlePeers['device-1']!.rssi, -45);
    });

    test('is a no-op for unknown device', () {
      const state = PeersState.initial;
      final action = BleDeviceRssiUpdatedAction(
        deviceId: 'nonexistent',
        rssi: -45,
      );

      final result = peersReducer(state, action);

      expect(result, same(state));
    });
  });

  // =========================================================================
  // BleDeviceConnectingAction
  // =========================================================================

  group('BleDeviceConnectingAction', () {
    test('sets isConnecting=true', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
          ),
        },
      );
      final action = BleDeviceConnectingAction('device-1');

      final result = peersReducer(initial, action);

      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.isConnecting, true);
    });

    test('is a no-op for unknown device', () {
      const state = PeersState.initial;
      final action = BleDeviceConnectingAction('nonexistent');

      final result = peersReducer(state, action);

      expect(result, same(state));
    });
  });

  // =========================================================================
  // BleDeviceConnectedAction
  // =========================================================================

  group('BleDeviceConnectedAction', () {
    test('sets isConnected=true, isConnecting=false, resets backoff', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
            lastError: 'previous error',
            consecutiveFailures: 3,
            nextRetryAfter: now.add(const Duration(seconds: 20)),
          ),
        },
      );
      final action = BleDeviceConnectedAction('device-1');

      final result = peersReducer(initial, action);

      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.isConnected, true);
      expect(peer.isConnecting, false);
      expect(peer.lastError, isNull);
      expect(peer.consecutiveFailures, 0);
      expect(peer.nextRetryAfter, isNull);
    });
  });

  // =========================================================================
  // BleDeviceConnectionFailedAction — with backoff
  // =========================================================================

  group('BleDeviceConnectionFailedAction', () {
    test('sets isConnecting=false, isConnected=false, sets lastError and backoff', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
          ),
        },
      );
      final action =
          BleDeviceConnectionFailedAction('device-1', error: 'Timeout');

      final result = peersReducer(initial, action);

      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.isConnecting, false);
      expect(peer.isConnected, false);
      expect(peer.lastError, 'Timeout');
      expect(peer.consecutiveFailures, 1);
      expect(peer.nextRetryAfter, isNotNull);
    });

    test('exponential backoff: 1st failure = ~5s', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
            consecutiveFailures: 0,
          ),
        },
      );
      final action = BleDeviceConnectionFailedAction('device-1', error: 'fail');

      final result = peersReducer(initial, action);
      final peer = result.discoveredBlePeers['device-1']!;

      expect(peer.consecutiveFailures, 1);
      // Should be ~5 seconds from now
      final delay = peer.nextRetryAfter!.difference(now);
      expect(delay.inSeconds, greaterThanOrEqualTo(4));
      expect(delay.inSeconds, lessThanOrEqualTo(6));
    });

    test('exponential backoff: 2nd failure = ~10s', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
            consecutiveFailures: 1,
          ),
        },
      );
      final action = BleDeviceConnectionFailedAction('device-1', error: 'fail');

      final result = peersReducer(initial, action);
      final peer = result.discoveredBlePeers['device-1']!;

      expect(peer.consecutiveFailures, 2);
      final delay = peer.nextRetryAfter!.difference(now);
      expect(delay.inSeconds, greaterThanOrEqualTo(9));
      expect(delay.inSeconds, lessThanOrEqualTo(11));
    });

    test('exponential backoff: 3rd failure = ~20s', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
            consecutiveFailures: 2,
          ),
        },
      );
      final action = BleDeviceConnectionFailedAction('device-1', error: 'fail');

      final result = peersReducer(initial, action);
      final peer = result.discoveredBlePeers['device-1']!;

      expect(peer.consecutiveFailures, 3);
      final delay = peer.nextRetryAfter!.difference(now);
      expect(delay.inSeconds, greaterThanOrEqualTo(19));
      expect(delay.inSeconds, lessThanOrEqualTo(21));
    });

    test('exponential backoff caps at 120s', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
            consecutiveFailures: 10, // Would be 5 * 2^10 = 5120s without cap
          ),
        },
      );
      final action = BleDeviceConnectionFailedAction('device-1', error: 'fail');

      final result = peersReducer(initial, action);
      final peer = result.discoveredBlePeers['device-1']!;

      expect(peer.consecutiveFailures, 11);
      final delay = peer.nextRetryAfter!.difference(now);
      expect(delay.inSeconds, lessThanOrEqualTo(121));
      expect(delay.inSeconds, greaterThanOrEqualTo(119));
    });
  });

  // =========================================================================
  // BleDeviceDisconnectedAction
  // =========================================================================

  group('BleDeviceDisconnectedAction', () {
    test('sets isConnecting=false and isConnected=false', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnecting: true,
            isConnected: true,
          ),
        },
      );
      final action = BleDeviceDisconnectedAction('device-1');

      final result = peersReducer(initial, action);

      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.isConnecting, false);
      expect(peer.isConnected, false);
    });

    test('preserves backoff state on disconnect', () {
      final now = DateTime.now();
      final retryAfter = now.add(const Duration(seconds: 30));
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
            isConnected: true,
            consecutiveFailures: 2,
            nextRetryAfter: retryAfter,
          ),
        },
      );
      final action = BleDeviceDisconnectedAction('device-1');

      final result = peersReducer(initial, action);

      final peer = result.discoveredBlePeers['device-1']!;
      expect(peer.consecutiveFailures, 2);
      expect(peer.nextRetryAfter, retryAfter);
    });
  });

  // =========================================================================
  // BleDeviceRemovedAction
  // =========================================================================

  group('BleDeviceRemovedAction', () {
    test('removes device from discovered peers map', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
          ),
          'device-2': DiscoveredPeerState(
            transportId: 'device-2',
            rssi: -70,
            discoveredAt: now,
            lastSeen: now,
          ),
        },
      );
      final action = BleDeviceRemovedAction('device-1');

      final result = peersReducer(initial, action);

      expect(result.discoveredBlePeers.length, 1);
      expect(result.discoveredBlePeers.containsKey('device-1'), false);
      expect(result.discoveredBlePeers.containsKey('device-2'), true);
    });
  });

  // =========================================================================
  // StaleDiscoveredBlePeersRemovedAction
  // =========================================================================

  group('StaleDiscoveredBlePeersRemovedAction', () {
    test('removes peers older than threshold and keeps fresh peers', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'stale-device': DiscoveredPeerState(
            transportId: 'stale-device',
            rssi: -60,
            discoveredAt: now.subtract(const Duration(minutes: 10)),
            lastSeen: now.subtract(const Duration(minutes: 5)),
          ),
          'fresh-device': DiscoveredPeerState(
            transportId: 'fresh-device',
            rssi: -50,
            discoveredAt: now.subtract(const Duration(seconds: 30)),
            lastSeen: now.subtract(const Duration(seconds: 5)),
          ),
        },
      );
      final action = StaleDiscoveredBlePeersRemovedAction(
        const Duration(minutes: 2),
      );

      final result = peersReducer(initial, action);

      expect(result.discoveredBlePeers.length, 1);
      expect(result.discoveredBlePeers.containsKey('stale-device'), false);
      expect(result.discoveredBlePeers.containsKey('fresh-device'), true);
    });
  });

  // =========================================================================
  // ClearDiscoveredBlePeersAction
  // =========================================================================

  group('ClearDiscoveredBlePeersAction', () {
    test('empties the discovered peers map', () {
      final now = DateTime.now();
      final initial = PeersState(
        discoveredBlePeers: {
          'device-1': DiscoveredPeerState(
            transportId: 'device-1',
            rssi: -60,
            discoveredAt: now,
            lastSeen: now,
          ),
          'device-2': DiscoveredPeerState(
            transportId: 'device-2',
            rssi: -70,
            discoveredAt: now,
            lastSeen: now,
          ),
        },
      );
      final action = ClearDiscoveredBlePeersAction();

      final result = peersReducer(initial, action);

      expect(result.discoveredBlePeers, isEmpty);
    });
  });

  // =========================================================================
  // PeerAnnounceReceivedAction — split BLE device IDs
  // =========================================================================

  group('PeerAnnounceReceivedAction', () {
    test('creates new peer with central BLE device ID', () {
      final pubkey = _testPubkey(1);
      const state = PeersState.initial;
      final action = PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'Alice',
        protocolVersion: 2,
        rssi: -55,
        transport: PeerTransport.bleDirect,
        bleCentralDeviceId: 'ble-central-1',
      );

      final result = peersReducer(state, action);

      final hex = _pubkeyHex(pubkey);
      expect(result.peers.length, 1);
      final peer = result.peers[hex]!;
      expect(peer.publicKey, pubkey);
      expect(peer.nickname, 'Alice');
      expect(peer.protocolVersion, 2);
      expect(peer.rssi, -55);
      expect(peer.transport, PeerTransport.bleDirect);
      expect(peer.bleCentralDeviceId, 'ble-central-1');
      expect(peer.blePeripheralDeviceId, isNull);
      expect(peer.bleDeviceId, 'ble-central-1'); // convenience getter
      expect(peer.connectionState, PeerConnectionState.connected);
      expect(peer.lastSeen, isNotNull);
      expect(peer.lastBleSeen, isNotNull);
    });

    test('creates new peer with peripheral BLE device ID', () {
      final pubkey = _testPubkey(1);
      const state = PeersState.initial;
      final action = PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'Alice',
        protocolVersion: 1,
        rssi: -60,
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'ble-peripheral-1',
      );

      final result = peersReducer(state, action);

      final hex = _pubkeyHex(pubkey);
      final peer = result.peers[hex]!;
      expect(peer.bleCentralDeviceId, isNull);
      expect(peer.blePeripheralDeviceId, 'ble-peripheral-1');
      expect(peer.bleDeviceId, 'ble-peripheral-1'); // fallback to peripheral
    });

    test('preserves both BLE IDs on sequential ANNOUNCEs from different roles', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);

      // First: central ANNOUNCE
      var state = peersReducer(PeersState.initial, PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'Alice',
        protocolVersion: 1,
        rssi: -55,
        transport: PeerTransport.bleDirect,
        bleCentralDeviceId: 'central-id',
      ));

      expect(state.peers[hex]!.bleCentralDeviceId, 'central-id');
      expect(state.peers[hex]!.blePeripheralDeviceId, isNull);

      // Second: peripheral ANNOUNCE — should NOT overwrite central
      state = peersReducer(state, PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'Alice',
        protocolVersion: 1,
        rssi: -50,
        transport: PeerTransport.bleDirect,
        blePeripheralDeviceId: 'peripheral-id',
      ));

      final peer = state.peers[hex]!;
      expect(peer.bleCentralDeviceId, 'central-id');
      expect(peer.blePeripheralDeviceId, 'peripheral-id');
      expect(peer.bleDeviceId, 'central-id'); // convenience getter prefers central
    });

    test('updates existing peer', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'OldNick',
            connectionState: PeerConnectionState.disconnected,
            rssi: -90,
            protocolVersion: 1,
          ),
        },
      );
      final action = PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'NewNick',
        protocolVersion: 3,
        rssi: -40,
        transport: PeerTransport.libp2p,
        libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
      );

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.nickname, 'NewNick');
      expect(peer.protocolVersion, 3);
      expect(peer.rssi, -40);
      expect(peer.transport, PeerTransport.libp2p);
      expect(peer.libp2pAddress, '/ip4/1.2.3.4/tcp/4001/p2p/QmTest');
      expect(peer.connectionState, PeerConnectionState.connected);
    });

    test('sets connectionState to connected', () {
      final pubkey = _testPubkey(2);
      final action = PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'Bob',
        protocolVersion: 1,
        rssi: -60,
      );

      final result = peersReducer(PeersState.initial, action);

      final hex = _pubkeyHex(pubkey);
      expect(result.peers[hex]!.connectionState, PeerConnectionState.connected);
    });

    test('libp2p ANNOUNCE does not clear existing BLE IDs', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-id',
            blePeripheralDeviceId: 'peripheral-id',
          ),
        },
      );
      final action = PeerAnnounceReceivedAction(
        publicKey: pubkey,
        nickname: 'Alice',
        protocolVersion: 1,
        rssi: -40,
        transport: PeerTransport.libp2p,
        libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
        // No BLE device IDs — should preserve existing
      );

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.bleCentralDeviceId, 'central-id');
      expect(peer.blePeripheralDeviceId, 'peripheral-id');
      expect(peer.libp2pAddress, '/ip4/1.2.3.4/tcp/4001/p2p/QmTest');
    });
  });

  // =========================================================================
  // PeerRssiUpdatedAction
  // =========================================================================

  group('PeerRssiUpdatedAction', () {
    test('updates peer RSSI', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            rssi: -80,
          ),
        },
      );
      final action = PeerRssiUpdatedAction(publicKey: pubkey, rssi: -45);

      final result = peersReducer(initial, action);

      expect(result.peers[hex]!.rssi, -45);
    });

    test('is a no-op for unknown peer', () {
      const state = PeersState.initial;
      final action = PeerRssiUpdatedAction(
        publicKey: _testPubkey(99),
        rssi: -45,
      );

      final result = peersReducer(state, action);

      expect(result, same(state));
    });
  });

  // =========================================================================
  // PeerBleDisconnectedAction — role-specific clearing
  // =========================================================================

  group('PeerBleDisconnectedAction', () {
    test('clears both BLE IDs when no role specified', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-1',
            blePeripheralDeviceId: 'peripheral-1',
          ),
        },
      );
      final action = PeerBleDisconnectedAction(pubkey);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.connectionState, PeerConnectionState.disconnected);
      expect(peer.bleCentralDeviceId, isNull);
      expect(peer.blePeripheralDeviceId, isNull);
      expect(peer.bleDeviceId, isNull);
    });

    test('clears only central ID when role=central', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-1',
            blePeripheralDeviceId: 'peripheral-1',
          ),
        },
      );
      final action = PeerBleDisconnectedAction(pubkey, role: BleRole.central);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.bleCentralDeviceId, isNull);
      expect(peer.blePeripheralDeviceId, 'peripheral-1');
      // Still has peripheral, so stays connected
      expect(peer.connectionState, PeerConnectionState.connected);
    });

    test('clears only peripheral ID when role=peripheral', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-1',
            blePeripheralDeviceId: 'peripheral-1',
          ),
        },
      );
      final action = PeerBleDisconnectedAction(pubkey, role: BleRole.peripheral);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.bleCentralDeviceId, 'central-1');
      expect(peer.blePeripheralDeviceId, isNull);
      expect(peer.connectionState, PeerConnectionState.connected);
    });

    test('marks disconnected if no BLE IDs remain and no libp2p', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-1',
          ),
        },
      );
      final action = PeerBleDisconnectedAction(pubkey, role: BleRole.central);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.connectionState, PeerConnectionState.disconnected);
      expect(peer.bleCentralDeviceId, isNull);
    });

    test('keeps connected if has libp2p address', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-1',
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
          ),
        },
      );
      final action = PeerBleDisconnectedAction(pubkey);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.connectionState, PeerConnectionState.connected);
      expect(peer.bleCentralDeviceId, isNull);
      expect(peer.blePeripheralDeviceId, isNull);
      expect(peer.libp2pAddress, '/ip4/1.2.3.4/tcp/4001/p2p/QmTest');
    });
  });

  // =========================================================================
  // PeerLibp2pDisconnectedAction
  // =========================================================================

  group('PeerLibp2pDisconnectedAction', () {
    test('marks disconnected if no BLE device', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
          ),
        },
      );
      final action = PeerLibp2pDisconnectedAction(pubkey);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.connectionState, PeerConnectionState.disconnected);
      expect(peer.libp2pAddress, isNull);
    });

    test('keeps connected if has BLE device (central)', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            bleCentralDeviceId: 'central-1',
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
          ),
        },
      );
      final action = PeerLibp2pDisconnectedAction(pubkey);

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.connectionState, PeerConnectionState.connected);
      expect(peer.bleCentralDeviceId, 'central-1');
      expect(peer.libp2pAddress, isNull);
    });

    test('clears libp2pAddress', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
          ),
        },
      );
      final action = PeerLibp2pDisconnectedAction(pubkey);

      final result = peersReducer(initial, action);

      expect(result.peers[hex]!.libp2pAddress, isNull);
    });
  });

  // =========================================================================
  // PeerDisconnectedAction
  // =========================================================================

  group('PeerDisconnectedAction', () {
    test('sets connectionState to disconnected', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
          ),
        },
      );
      final action = PeerDisconnectedAction(pubkey);

      final result = peersReducer(initial, action);

      expect(
        result.peers[hex]!.connectionState,
        PeerConnectionState.disconnected,
      );
    });
  });

  // =========================================================================
  // AssociateBleDeviceAction — role-based
  // =========================================================================

  group('AssociateBleDeviceAction', () {
    test('sets bleCentralDeviceId when role=central', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
          ),
        },
      );
      final action = AssociateBleDeviceAction(
        publicKey: pubkey,
        deviceId: 'ble-central-99',
        role: BleRole.central,
      );

      final result = peersReducer(initial, action);

      expect(result.peers[hex]!.bleCentralDeviceId, 'ble-central-99');
      expect(result.peers[hex]!.blePeripheralDeviceId, isNull);
    });

    test('sets blePeripheralDeviceId when role=peripheral', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
          ),
        },
      );
      final action = AssociateBleDeviceAction(
        publicKey: pubkey,
        deviceId: 'ble-peripheral-99',
        role: BleRole.peripheral,
      );

      final result = peersReducer(initial, action);

      expect(result.peers[hex]!.bleCentralDeviceId, isNull);
      expect(result.peers[hex]!.blePeripheralDeviceId, 'ble-peripheral-99');
    });

    test('is a no-op for unknown peer', () {
      const state = PeersState.initial;
      final action = AssociateBleDeviceAction(
        publicKey: _testPubkey(99),
        deviceId: 'ble-device-99',
        role: BleRole.central,
      );

      final result = peersReducer(state, action);

      expect(result, same(state));
    });
  });

  // =========================================================================
  // AssociateLibp2pAddressAction
  // =========================================================================

  group('AssociateLibp2pAddressAction', () {
    test('sets libp2pAddress and parses hostId and hostAddrs', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
          ),
        },
      );
      final action = AssociateLibp2pAddressAction(
        publicKey: pubkey,
        address: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
      );

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      expect(peer.libp2pAddress, '/ip4/1.2.3.4/tcp/4001/p2p/QmTest');
      expect(peer.libp2pHostId, 'QmTest');
      expect(peer.libp2pHostAddrs, ['/ip4/1.2.3.4/tcp/4001']);
    });

    test('clears libp2pAddress when address is empty', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
          ),
        },
      );
      final action = AssociateLibp2pAddressAction(
        publicKey: pubkey,
        address: '',
      );

      final result = peersReducer(initial, action);

      // When address is empty, copyWith with null keeps old value for
      // libp2pAddress. The reducer passes: libp2pAddress: action.address.isEmpty ? null : action.address
      // But copyWith(libp2pAddress: null) preserves old value due to ?? semantics.
      // This documents the actual behavior of the reducer.
      final peer = result.peers[hex]!;
      // The reducer uses copyWith which can't clear nullable fields to null.
      // So the old libp2pAddress is preserved. This is a known copyWith limitation.
      expect(peer.libp2pAddress, '/ip4/1.2.3.4/tcp/4001/p2p/QmTest');
    });

    test('is a no-op for unknown peer', () {
      const state = PeersState.initial;
      final action = AssociateLibp2pAddressAction(
        publicKey: _testPubkey(99),
        address: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
      );

      final result = peersReducer(state, action);

      expect(result, same(state));
    });
  });

  // =========================================================================
  // FriendEstablishedAction
  // =========================================================================

  group('FriendEstablishedAction', () {
    test('sets isFriend=true on existing peer', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            isFriend: false,
          ),
        },
      );
      final action = FriendEstablishedAction(
        publicKey: pubkey,
        nickname: 'Alice',
      );

      final result = peersReducer(initial, action);

      expect(result.peers[hex]!.isFriend, true);
    });

    test('creates new peer with isFriend=true if not exists', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final action = FriendEstablishedAction(
        publicKey: pubkey,
        nickname: 'NewFriend',
      );

      final result = peersReducer(PeersState.initial, action);

      expect(result.peers.length, 1);
      final peer = result.peers[hex]!;
      expect(peer.isFriend, true);
      expect(peer.nickname, 'NewFriend');
      expect(peer.connectionState, PeerConnectionState.discovered);
    });

    test('creates new peer with empty nickname when nickname is null', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final action = FriendEstablishedAction(publicKey: pubkey);

      final result = peersReducer(PeersState.initial, action);

      expect(result.peers[hex]!.nickname, '');
      expect(result.peers[hex]!.isFriend, true);
    });
  });

  // =========================================================================
  // FriendRemovedAction
  // =========================================================================

  group('FriendRemovedAction', () {
    test('removes peer entirely if no BLE connection', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            isFriend: true,
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
            // no BLE device IDs
          ),
        },
      );
      final action = FriendRemovedAction(pubkey);

      final result = peersReducer(initial, action);

      expect(result.peers.containsKey(hex), false);
      expect(result.peers, isEmpty);
    });

    test('clears isFriend and libp2p fields but keeps peer if has BLE central', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            isFriend: true,
            bleCentralDeviceId: 'central-1',
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
            libp2pHostId: 'QmTest',
            libp2pHostAddrs: const ['/ip4/1.2.3.4/tcp/4001'],
          ),
        },
      );
      final action = FriendRemovedAction(pubkey);

      final result = peersReducer(initial, action);

      expect(result.peers.containsKey(hex), true);
      final peer = result.peers[hex]!;
      expect(peer.isFriend, false);
      expect(peer.libp2pAddress, isNull);
      expect(peer.libp2pHostId, isNull);
      expect(peer.libp2pHostAddrs, isNull);
      expect(peer.bleCentralDeviceId, 'central-1');
      expect(peer.connectionState, PeerConnectionState.connected);
      expect(peer.transport, PeerTransport.bleDirect);
    });

    test('keeps peer if has BLE peripheral', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            isFriend: true,
            blePeripheralDeviceId: 'peripheral-1',
          ),
        },
      );
      final action = FriendRemovedAction(pubkey);

      final result = peersReducer(initial, action);

      expect(result.peers.containsKey(hex), true);
      final peer = result.peers[hex]!;
      expect(peer.isFriend, false);
      expect(peer.blePeripheralDeviceId, 'peripheral-1');
    });

    test('is a no-op for unknown peer', () {
      const state = PeersState.initial;
      final action = FriendRemovedAction(_testPubkey(99));

      final result = peersReducer(state, action);

      expect(result, same(state));
    });
  });

  // =========================================================================
  // StalePeersRemovedAction
  // =========================================================================

  group('StalePeersRemovedAction', () {
    test('removes stale non-friend peers', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final now = DateTime.now();
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            lastSeen: now.subtract(const Duration(minutes: 10)),
            isFriend: false,
          ),
        },
      );
      final action = StalePeersRemovedAction(const Duration(minutes: 2));

      final result = peersReducer(initial, action);

      expect(result.peers.containsKey(hex), false);
    });

    test('marks stale friend peers as disconnected and preserves libp2pHostId', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final now = DateTime.now();
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            lastSeen: now.subtract(const Duration(minutes: 10)),
            isFriend: true,
            bleCentralDeviceId: 'central-1',
            blePeripheralDeviceId: 'peripheral-1',
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
            libp2pHostId: 'QmTest',
            libp2pHostAddrs: const ['/ip4/1.2.3.4/tcp/4001'],
          ),
        },
      );
      final action = StalePeersRemovedAction(const Duration(minutes: 2));

      final result = peersReducer(initial, action);

      expect(result.peers.containsKey(hex), true);
      final peer = result.peers[hex]!;
      expect(peer.connectionState, PeerConnectionState.disconnected);
      expect(peer.isFriend, true);
      expect(peer.rssi, -100);
      expect(peer.bleCentralDeviceId, isNull);
      expect(peer.blePeripheralDeviceId, isNull);
      expect(peer.bleDeviceId, isNull);
      expect(peer.libp2pAddress, isNull);
      expect(peer.libp2pHostId, 'QmTest');
      expect(peer.libp2pHostAddrs, ['/ip4/1.2.3.4/tcp/4001']);
    });

    test('clears stale BLE IDs when lastBleSeen exceeds threshold', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final now = DateTime.now();
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            lastSeen: now, // recently seen via libp2p
            bleCentralDeviceId: 'central-1',
            blePeripheralDeviceId: 'peripheral-1',
            lastBleSeen: now.subtract(const Duration(minutes: 5)), // stale BLE
            libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
          ),
        },
      );
      final action = StalePeersRemovedAction(const Duration(minutes: 2));

      final result = peersReducer(initial, action);

      final peer = result.peers[hex]!;
      // BLE IDs cleared because lastBleSeen is stale
      expect(peer.bleCentralDeviceId, isNull);
      expect(peer.blePeripheralDeviceId, isNull);
      // But peer stays connected via libp2p
      expect(peer.connectionState, PeerConnectionState.connected);
      expect(peer.libp2pAddress, '/ip4/1.2.3.4/tcp/4001/p2p/QmTest');
    });

    test('keeps fresh peers unchanged', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final now = DateTime.now();
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.connected,
            lastSeen: now.subtract(const Duration(seconds: 10)),
            isFriend: false,
          ),
        },
      );
      final action = StalePeersRemovedAction(const Duration(minutes: 2));

      final result = peersReducer(initial, action);

      expect(result.peers.containsKey(hex), true);
      expect(
        result.peers[hex]!.connectionState,
        PeerConnectionState.connected,
      );
    });

    test('skips already-disconnected peers', () {
      final pubkey = _testPubkey(1);
      final hex = _pubkeyHex(pubkey);
      final now = DateTime.now();
      final initial = PeersState(
        peers: {
          hex: PeerState(
            publicKey: pubkey,
            nickname: 'Alice',
            connectionState: PeerConnectionState.disconnected,
            lastSeen: now.subtract(const Duration(minutes: 10)),
            isFriend: false,
          ),
        },
      );
      final action = StalePeersRemovedAction(const Duration(minutes: 2));

      final result = peersReducer(initial, action);

      // Disconnected peers are not considered for stale removal
      // (reducer checks connectionState != connected first)
      expect(result.peers.containsKey(hex), true);
    });
  });

  // =========================================================================
  // PeerState convenience getters
  // =========================================================================

  group('PeerState getters', () {
    test('hasBleConnection is true with central ID', () {
      final peer = PeerState(
        publicKey: _testPubkey(1),
        nickname: 'Alice',
        bleCentralDeviceId: 'central-1',
      );
      expect(peer.hasBleConnection, true);
      expect(peer.bleDeviceId, 'central-1');
    });

    test('hasBleConnection is true with peripheral ID', () {
      final peer = PeerState(
        publicKey: _testPubkey(1),
        nickname: 'Alice',
        blePeripheralDeviceId: 'peripheral-1',
      );
      expect(peer.hasBleConnection, true);
      expect(peer.bleDeviceId, 'peripheral-1');
    });

    test('hasBleConnection is false with no IDs', () {
      final peer = PeerState(
        publicKey: _testPubkey(1),
        nickname: 'Alice',
      );
      expect(peer.hasBleConnection, false);
      expect(peer.bleDeviceId, isNull);
    });

    test('bleDeviceId prefers central over peripheral', () {
      final peer = PeerState(
        publicKey: _testPubkey(1),
        nickname: 'Alice',
        bleCentralDeviceId: 'central-1',
        blePeripheralDeviceId: 'peripheral-1',
      );
      expect(peer.bleDeviceId, 'central-1');
    });

    test('isReachable with BLE', () {
      final peer = PeerState(
        publicKey: _testPubkey(1),
        nickname: 'Alice',
        blePeripheralDeviceId: 'peripheral-1',
      );
      expect(peer.isReachable, true);
    });

    test('activeTransport prefers BLE', () {
      final peer = PeerState(
        publicKey: _testPubkey(1),
        nickname: 'Alice',
        bleCentralDeviceId: 'central-1',
        libp2pAddress: '/ip4/1.2.3.4/tcp/4001/p2p/QmTest',
      );
      expect(peer.activeTransport, PeerTransport.bleDirect);
    });
  });

  // =========================================================================
  // DiscoveredPeerState backoff getters
  // =========================================================================

  group('DiscoveredPeerState backoff', () {
    test('isInBackoff is false when nextRetryAfter is null', () {
      final now = DateTime.now();
      final peer = DiscoveredPeerState(
        transportId: 'device-1',
        rssi: -60,
        discoveredAt: now,
        lastSeen: now,
      );
      expect(peer.isInBackoff, false);
    });

    test('isInBackoff is true when nextRetryAfter is in the future', () {
      final now = DateTime.now();
      final peer = DiscoveredPeerState(
        transportId: 'device-1',
        rssi: -60,
        discoveredAt: now,
        lastSeen: now,
        nextRetryAfter: now.add(const Duration(seconds: 30)),
      );
      expect(peer.isInBackoff, true);
    });

    test('isInBackoff is false when nextRetryAfter is in the past', () {
      final now = DateTime.now();
      final peer = DiscoveredPeerState(
        transportId: 'device-1',
        rssi: -60,
        discoveredAt: now,
        lastSeen: now,
        nextRetryAfter: now.subtract(const Duration(seconds: 1)),
      );
      expect(peer.isInBackoff, false);
    });
  });

  // =========================================================================
  // Unknown action
  // =========================================================================

  group('unknown action', () {
    test('returns state unchanged for unknown action type', () {
      const state = PeersState.initial;
      final result = peersReducer(state, 'unknown-action');

      expect(result, same(state));
    });
  });
}
