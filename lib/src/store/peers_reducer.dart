import '../models/peer.dart';
import 'peers_state.dart';
import 'peers_actions.dart';

/// Reducer for peers-related state
PeersState peersReducer(PeersState state, dynamic action) {
  // ===== BLE Discovery Actions =====
  
  if (action is BleDeviceDiscoveredAction) {
    // TODO: why is nickname here? it comes in the announce
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
      // TODO: this should be a different action, use update rssi
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
      final updated = existing.copyWith(
        isConnecting: false,
        isConnected: true,
        lastError: null,
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
      final updated = existing.copyWith(
        isConnecting: false,
        isConnected: false,
        lastError: action.error,
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
    
    final isBle = action.transport == PeerTransport.bleDirect;

    if (existing == null) {
      // New peer
      final newPeer = PeerState(
        publicKey: action.publicKey,
        nickname: action.nickname,
        connectionState: PeerConnectionState.connected,
        transport: action.transport,
        rssi: action.rssi,
        protocolVersion: action.protocolVersion,
        lastSeen: now,
        bleDeviceId: action.bleDeviceId,
        lastBleSeen: isBle ? now : null,
        libp2pAddress: action.libp2pAddress,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = newPeer,
      );
    } else {
      // Update existing peer.
      // Use direct constructor (not copyWith) because bleDeviceId may
      // legitimately become null when the peer is no longer nearby via BLE.
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: action.nickname,
        connectionState: PeerConnectionState.connected,
        transport: action.transport,
        rssi: action.rssi,
        protocolVersion: action.protocolVersion,
        lastSeen: now,
        bleDeviceId: action.bleDeviceId,
        lastBleSeen: isBle ? now : existing.lastBleSeen,
        libp2pAddress: action.libp2pAddress ?? existing.libp2pAddress,
        isFriend: existing.isFriend,
        libp2pHostId: existing.libp2pHostId,
        libp2pHostAddrs: existing.libp2pHostAddrs,
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
      // If no other transport, mark as disconnected
      final newConnectionState = existing.libp2pAddress != null
          ? existing.connectionState
          : PeerConnectionState.disconnected;
      // Construct directly to clear bleDeviceId (copyWith with null keeps old value)
      final updated = PeerState(
        publicKey: existing.publicKey,
        nickname: existing.nickname,
        connectionState: newConnectionState,
        transport: existing.transport,
        rssi: existing.rssi,
        protocolVersion: existing.protocolVersion,
        lastSeen: existing.lastSeen,
        bleDeviceId: null,  // Clear BLE device ID
        lastBleSeen: null,
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
      final newConnectionState = existing.bleDeviceId != null
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
        bleDeviceId: existing.bleDeviceId,
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
      // Clear stale bleDeviceId if no BLE ANNOUNCE received within threshold.
      // Without this, a peer that keeps sending libp2p ANNOUNCEs retains a
      // stale bleDeviceId forever via the ?? operator in
      // PeerAnnounceReceivedAction, making them appear in "Nearby" instead of
      // "Friends Online".
      if (peer.bleDeviceId != null && peer.lastBleSeen != null) {
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
            bleDeviceId: null,
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
          // Clear bleDeviceId (out of BLE range) and libp2pAddress (active connection).
          newMap[key] = PeerState(
            publicKey: peer.publicKey,
            nickname: peer.nickname,
            connectionState: PeerConnectionState.disconnected,
            transport: peer.transport,
            rssi: -100,
            protocolVersion: peer.protocolVersion,
            lastSeen: peer.lastSeen,
            bleDeviceId: null,
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
      final updated = existing.copyWith(bleDeviceId: action.deviceId);
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
      // Parse address to extract hostId and baseAddr
      String? libp2pHostId;
      List<String>? libp2pHostAddrs;

      if (action.address.isNotEmpty) {
        final parts = action.address.split('/p2p/');
        if (parts.length == 2) {
          libp2pHostId = parts[1];
          libp2pHostAddrs = [parts[0]];
        }
      }

      final updated = existing.copyWith(
        libp2pAddress: action.address.isEmpty ? null : action.address,
        libp2pHostId: libp2pHostId,
        libp2pHostAddrs: libp2pHostAddrs,
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
      if (existing.bleDeviceId == null) {
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
        bleDeviceId: existing.bleDeviceId,
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
