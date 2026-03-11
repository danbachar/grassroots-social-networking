import 'dart:math' as math;
import '../models/peer.dart';
import 'peers_state.dart';
import 'peers_actions.dart';

/// Initial backoff delay in seconds after first failure
const _initialBackoffSeconds = 5;

/// Maximum backoff delay in seconds (cap)
const _maxBackoffSeconds = 120;

/// Reducer for peers-related state
PeersState peersReducer(PeersState state, dynamic action) {
  // ===== BLE Discovery Actions =====

  if (action is BleDeviceDiscoveredAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    final now = DateTime.now();

    if (existing == null) {
      // New discovery
      final newPeer = DiscoveredPeerState(
        transportId: action.deviceId,
        displayName: action.displayName,
        rssi: action.rssi,
        discoveredAt: now,
        lastSeen: now,
        serviceUuid: action.serviceUuid,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = newPeer,
      );
    } else {
      // Update existing
      final updated = existing.copyWith(
        rssi: action.rssi,
        lastSeen: now,
        displayName: (action.displayName?.isNotEmpty ?? false)
            ? action.displayName
            : existing.displayName,
        serviceUuid: action.serviceUuid ?? existing.serviceUuid,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
  }

  if (action is BleDeviceRssiUpdatedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        rssi: action.rssi,
        lastSeen: DateTime.now(),
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }

  if (action is BleDeviceConnectingAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isConnecting: true,
        connectionAttempts: existing.connectionAttempts + 1,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }

  if (action is BleDeviceConnectedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      // Reset backoff on successful connection
      final updated = DiscoveredPeerState(
        transportId: existing.transportId,
        displayName: existing.displayName,
        rssi: existing.rssi,
        discoveredAt: existing.discoveredAt,
        lastSeen: existing.lastSeen,
        isConnecting: false,
        isConnected: true,
        lastError: null,
        publicKey: existing.publicKey,
        serviceUuid: existing.serviceUuid,
        consecutiveFailures: 0,
        nextRetryAfter: null,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }

  if (action is BleDeviceConnectionFailedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      // Calculate exponential backoff: min(initialDelay * 2^(failures), maxDelay)
      final newFailures = existing.consecutiveFailures + 1;
      final backoffSeconds = math.min(
        _initialBackoffSeconds * (1 << (newFailures - 1)),
        _maxBackoffSeconds,
      );

      final updated = DiscoveredPeerState(
        transportId: existing.transportId,
        displayName: existing.displayName,
        rssi: existing.rssi,
        discoveredAt: existing.discoveredAt,
        lastSeen: existing.lastSeen,
        isConnecting: false,
        isConnected: false,
        lastError: action.error,
        publicKey: existing.publicKey,
        serviceUuid: existing.serviceUuid,
        consecutiveFailures: newFailures,
        nextRetryAfter: DateTime.now().add(Duration(seconds: backoffSeconds)),
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }

  if (action is BleDeviceDisconnectedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      // Preserve backoff state on disconnect (don't reset)
      final updated = existing.copyWith(
        isConnecting: false,
        isConnected: false,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }

  if (action is BleDeviceRemovedAction) {
    final newMap = Map<String, DiscoveredPeerState>.from(state.discoveredBlePeers);
    newMap.remove(action.deviceId);
    return state.copyWith(discoveredBlePeers: newMap);
  }

  if (action is StaleDiscoveredBlePeersRemovedAction) {
    final now = DateTime.now();
    final newMap = Map<String, DiscoveredPeerState>.from(state.discoveredBlePeers);
    newMap.removeWhere((_, peer) {
      final timeSinceLastSeen = now.difference(peer.lastSeen);
      return timeSinceLastSeen > action.staleThreshold;
    });
    return state.copyWith(discoveredBlePeers: newMap);
  }

  if (action is ClearDiscoveredBlePeersAction) {
    return state.copyWith(discoveredBlePeers: {});
  }

  // ===== Libp2p Discovery Actions =====

  if (action is Libp2pPeerDiscoveredAction) {
    final existing = state.discoveredLibp2pPeers[action.peerId];
    final now = DateTime.now();

    if (existing == null) {
      final newPeer = DiscoveredPeerState(
        transportId: action.peerId,
        displayName: action.displayName,
        rssi: 0, // libp2p doesn't have RSSI
        discoveredAt: now,
        lastSeen: now,
      );
      return state.copyWith(
        discoveredLibp2pPeers: Map.from(state.discoveredLibp2pPeers)
          ..[action.peerId] = newPeer,
      );
    } else {
      final updated = existing.copyWith(lastSeen: now);
      return state.copyWith(
        discoveredLibp2pPeers: Map.from(state.discoveredLibp2pPeers)
          ..[action.peerId] = updated,
      );
    }
  }

  if (action is ClearDiscoveredLibp2pPeersAction) {
    return state.copyWith(discoveredLibp2pPeers: {});
  }

  // ===== Peer Identity Actions =====

  if (action is PeerAnnounceReceivedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    final now = DateTime.now();

    // ANNOUNCE addresses are the source of truth — always overwrite.
    // If a peer removed an address, it's stale and should be cleared.
    final parsed = _parseLibp2pAddresses(action.libp2pAddresses);

    // libp2pAddress = the verified working connection address.
    // - If existing address is still in the new ANNOUNCE list: keep it
    // - If existing address is NOT in the new list: stale, clear it
    // - If no existing and ANNOUNCE came via libp2p: use first address
    // - If no existing and ANNOUNCE came via BLE: null (side-effect connects)
    final existingLibp2pAddr = existing?.libp2pAddress;
    String? libp2pAddress;
    if (existingLibp2pAddr != null && action.libp2pAddresses.contains(existingLibp2pAddr)) {
      libp2pAddress = existingLibp2pAddr;
    } else if (action.transport == PeerTransport.libp2p && action.libp2pAddresses.isNotEmpty) {
      libp2pAddress = action.libp2pAddresses.first;
    }

    final isBle = action.transport == PeerTransport.bleDirect;

    if (existing == null) {
      // New peer — set only the field matching the role
      final newPeer = PeerState(
        publicKey: action.publicKey,
        nickname: action.nickname,
        connectionState: PeerConnectionState.connected,
        transport: action.transport,
        rssi: action.rssi,
        protocolVersion: action.protocolVersion,
        lastSeen: now,
        bleCentralDeviceId: action.bleCentralDeviceId,
        blePeripheralDeviceId: action.blePeripheralDeviceId,
        lastBleSeen: isBle ? now : null,
        libp2pAddress: libp2pAddress,
        libp2pHostId: parsed.hostId,
        libp2pHostAddrs: parsed.baseAddresses,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = newPeer,
      );
    } else {
      // Update existing peer.
      // Merge BLE IDs: only update the field that's provided in this action,
      // preserve the other from existing state.
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: action.nickname,
        connectionState: PeerConnectionState.connected,
        transport: action.transport,
        rssi: action.rssi,
        protocolVersion: action.protocolVersion,
        lastSeen: now,
        bleCentralDeviceId: action.bleCentralDeviceId ?? existing.bleCentralDeviceId,
        blePeripheralDeviceId: action.blePeripheralDeviceId ?? existing.blePeripheralDeviceId,
        lastBleSeen: isBle ? now : existing.lastBleSeen,
        libp2pAddress: libp2pAddress,
        libp2pHostId: parsed.hostId,
        libp2pHostAddrs: parsed.baseAddresses,
        isFriend: existing.isFriend,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
  }

  if (action is PeerRssiUpdatedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(
        rssi: action.rssi,
        lastSeen: DateTime.now(),
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is PeerBleDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // Determine which BLE IDs to clear based on role
      final clearCentral = action.role == null || action.role == BleRole.central;
      final clearPeripheral = action.role == null || action.role == BleRole.peripheral;

      final newCentralId = clearCentral ? null : existing.bleCentralDeviceId;
      final newPeripheralId = clearPeripheral ? null : existing.blePeripheralDeviceId;
      final hasAnyBle = newCentralId != null || newPeripheralId != null;

      // If no other transport, mark as disconnected
      final newConnectionState = (hasAnyBle || existing.libp2pAddress != null)
          ? existing.connectionState
          : PeerConnectionState.disconnected;

      // Construct directly to allow clearing nullable fields
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: newConnectionState,
        transport: existing.transport,
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleCentralDeviceId: newCentralId,
        blePeripheralDeviceId: newPeripheralId,
        lastBleSeen: hasAnyBle ? existing.lastBleSeen : null,
        libp2pAddress: existing.libp2pAddress,
        isFriend: existing.isFriend,
        libp2pHostId: existing.libp2pHostId,
        libp2pHostAddrs: existing.libp2pHostAddrs,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is PeerLibp2pDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // If no other transport, mark as disconnected
      final newConnectionState = existing.hasBleConnection
          ? existing.connectionState
          : PeerConnectionState.disconnected;
      // Construct directly to clear libp2pAddress (copyWith with null keeps old value)
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: newConnectionState,
        transport: existing.transport,
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleCentralDeviceId: existing.bleCentralDeviceId,
        blePeripheralDeviceId: existing.blePeripheralDeviceId,
        lastBleSeen: existing.lastBleSeen,
        libp2pAddress: null,  // Clear libp2p address
        isFriend: existing.isFriend,
        libp2pHostId: existing.libp2pHostId,
        libp2pHostAddrs: existing.libp2pHostAddrs,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is PeerDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(
        connectionState: PeerConnectionState.disconnected,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is PeerRemovedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final newMap = Map<String, PeerState>.from(state.peers);
    newMap.remove(pubkeyHex);
    return state.copyWith(peers: newMap);
  }

  // TODO: Add stale detection for libp2p-only peers (peers connected solely via
  // libp2p that go silent should eventually be marked disconnected).
  if (action is StalePeersRemovedAction) {
    final now = DateTime.now();
    final newMap = Map<String, PeerState>.from(state.peers);
    final staleKeys = <String>[];
    newMap.forEach((key, peer) {
      // Clear stale BLE IDs if no BLE ANNOUNCE received within threshold.
      if (peer.hasBleConnection && peer.lastBleSeen != null) {
        final timeSinceBleSeen = now.difference(peer.lastBleSeen!);
        if (timeSinceBleSeen > action.staleThreshold) {
          newMap[key] = PeerState(
            publicKey: peer.publicKey,
            nickname: peer.nickname,
            connectionState: peer.connectionState,
            transport: peer.transport,
            rssi: peer.rssi,
            protocolVersion: peer.protocolVersion,
            lastSeen: peer.lastSeen,
            bleCentralDeviceId: null,
            blePeripheralDeviceId: null,
            lastBleSeen: null,
            libp2pAddress: peer.libp2pAddress,
            isFriend: peer.isFriend,
            libp2pHostId: peer.libp2pHostId,
            libp2pHostAddrs: peer.libp2pHostAddrs,
          );
          return;
        }
      }

      if (peer.connectionState != PeerConnectionState.connected) return;
      if (peer.lastSeen == null) return;
      final timeSinceLastSeen = now.difference(peer.lastSeen!);
      if (timeSinceLastSeen > action.staleThreshold) {
        if (peer.isFriend) {
          // Friends are marked as disconnected when stale (no ANNOUNCE received).
          // Keep libp2pHostId/libp2pHostAddrs for reconnection when they come back.
          // Clear BLE IDs (out of BLE range) and libp2pAddress (active connection).
          newMap[key] = PeerState(
            publicKey: peer.publicKey,
            nickname: peer.nickname,
            connectionState: PeerConnectionState.disconnected,
            transport: peer.transport,
            rssi: -100,
            protocolVersion: peer.protocolVersion,
            lastSeen: peer.lastSeen,
            bleCentralDeviceId: null,
            blePeripheralDeviceId: null,
            lastBleSeen: null,
            libp2pAddress: null,  // Clear active connection address
            isFriend: true,
            libp2pHostId: peer.libp2pHostId,  // Keep for reconnection
            libp2pHostAddrs: peer.libp2pHostAddrs,  // Keep for reconnection
          );
        } else {
          staleKeys.add(key);
        }
      }
    });
    for (final key in staleKeys) {
      newMap.remove(key);
    }
    return state.copyWith(peers: newMap);
  }

  if (action is ClearAllPeersAction) {
    return state.copyWith(peers: {});
  }

  // ===== Association Actions =====

  if (action is AssociateBleDeviceAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = action.role == BleRole.central
          ? existing.copyWith(bleCentralDeviceId: action.deviceId)
          : existing.copyWith(blePeripheralDeviceId: action.deviceId);
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is AssociateLibp2pAddressAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // Extract hostId from the address
      String? libp2pHostId;
      if (action.address.isNotEmpty) {
        final parts = action.address.split('/p2p/');
        if (parts.length >= 2) {
          libp2pHostId = parts.last;
        }
      }

      // Update libp2pAddress, libp2pHostId, and mark as connected.
      // Do NOT overwrite libp2pHostAddrs — the full backup list
      // comes from ANNOUNCE and should be preserved.
      final updated = existing.copyWith(
        libp2pAddress: action.address.isEmpty ? null : action.address,
        libp2pHostId: libp2pHostId,
        connectionState: PeerConnectionState.connected,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  // ===== Friendship Actions =====

  if (action is FriendEstablishedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];

    if (existing != null) {
      final updated = existing.copyWith(
        isFriend: true,
        nickname: action.nickname ?? existing.nickname,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    } else {
      // Peer may not exist yet (e.g. hydrated from FriendshipStore on startup)
      final newPeer = PeerState(
        publicKey: action.publicKey,
        nickname: action.nickname ?? '',
        connectionState: PeerConnectionState.discovered,
        lastSeen: DateTime.now(),
        isFriend: true,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = newPeer,
      );
    }
  }

  if (action is FriendRemovedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // If peer has no BLE connection, remove them entirely
      // (they were only reachable via libp2p friendship)
      if (!existing.hasBleConnection) {
        final newMap = Map<String, PeerState>.from(state.peers);
        newMap.remove(pubkeyHex);
        return state.copyWith(peers: newMap);
      }

      // Peer is still nearby via BLE - keep them but clear friend status
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: PeerConnectionState.connected,
        transport: PeerTransport.bleDirect, // Reset to BLE
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleCentralDeviceId: existing.bleCentralDeviceId,
        blePeripheralDeviceId: existing.blePeripheralDeviceId,
        lastBleSeen: existing.lastBleSeen,
        // Clear all libp2p/friend fields
        isFriend: false,
        libp2pAddress: null,
        libp2pHostId: null,
        libp2pHostAddrs: null,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  return state;
}

String _pubkeyToHex(List<int> pubkey) {
  return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Parse a list of libp2p multiaddrs to extract the hostId and base addresses.
/// Each address may be in the form `/ip6/.../udp/.../udx/p2p/QmABC`.
/// Returns the first hostId found and all base addresses (with /p2p/ suffix stripped).
({String? hostId, List<String> baseAddresses}) _parseLibp2pAddresses(List<String> addresses) {
  String? hostId;
  final baseAddresses = <String>[];

  for (final addr in addresses) {
    final parts = addr.split('/p2p/');
    if (parts.length >= 2) {
      // Last /p2p/ segment is the hostId (handles circuit relay addresses too)
      final id = parts.last;
      hostId ??= id;
      // Base address is everything before the last /p2p/ segment
      baseAddresses.add(parts.sublist(0, parts.length - 1).join('/p2p/'));
    } else {
      // No /p2p/ component — use as-is
      baseAddresses.add(addr);
    }
  }

  return (hostId: hostId, baseAddresses: baseAddresses);
}
