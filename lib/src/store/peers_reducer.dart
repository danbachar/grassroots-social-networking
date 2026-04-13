import 'dart:math' as math;
import '../models/peer.dart';
import '../transport/address_utils.dart';
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
        isBlacklisted: existing.isBlacklisted,
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
        isBlacklisted: existing.isBlacklisted,
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

  if (action is BleDeviceBlacklistedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isBlacklisted: true,
      );
      return state.copyWith(
        discoveredBlePeers: Map.from(state.discoveredBlePeers)
          ..[action.deviceId] = updated,
      );
    }
    return state;
  }

  if (action is BleDeviceUnblacklistedAction) {
    final existing = state.discoveredBlePeers[action.deviceId];
    if (existing != null) {
      final updated = existing.copyWith(
        isBlacklisted: false,
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

  // ===== Peer Identity Actions =====

  if (action is PeerAnnounceReceivedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    final now = DateTime.now();

    final isBle = action.transport == PeerTransport.bleDirect;

    // Derive well-connected status from the UDP address in this ANNOUNCE.
    // A peer is well-connected if they advertise a globally routable IPv6 address.
    // The address in the ANNOUNCE is authoritative — if absent, the peer has no address.
    final wellConnected = action.udpAddress != null &&
        isGloballyRoutableAddress(action.udpAddress!);

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
        udpAddress: action.udpAddress,
        linkLocalAddress: action.linkLocalAddress,
        isWellConnected: wellConnected,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = newPeer,
      );
    } else {
      // Update existing peer.
      // Merge BLE IDs: only update the field that's provided in this action,
      // preserve the other from existing state.
      //
      // TODO: Revert to unconditional `udpAddress: action.udpAddress` once
      // the BLE layer sends EITHER a friend ANNOUNCE (with address) OR a
      // non-friend ANNOUNCE (without address) per recipient — never both.
      // Currently a friend receives both because the peripheral can't
      // reliably determine which centrals are friends (BLE device ID
      // rotation). The non-friend broadcast (no address) arrives and nukes
      // the address set by the UDP ANNOUNCE, causing peers to flicker in
      // the online friends list. This null-coalescing is a workaround.
      //
      // TODO: Fix BLE peripheral to reliably map central device IDs to
      // friend public keys so it can skip friends in the broadcast and
      // only send them the directed friend ANNOUNCE with address.
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
        udpAddress: action.udpAddress ?? existing.udpAddress,
        linkLocalAddress: action.linkLocalAddress ?? existing.linkLocalAddress,
        isFriend: existing.isFriend,
        isWellConnected: action.udpAddress != null ? wellConnected : existing.isWellConnected,
        hasLiveUdpConnection: existing.hasLiveUdpConnection,
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
      final newConnectionState = (hasAnyBle || existing.hasLiveUdpConnection)
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
        udpAddress: existing.udpAddress,
        linkLocalAddress: existing.linkLocalAddress,
        isFriend: existing.isFriend,
        isWellConnected: existing.isWellConnected,
        hasLiveUdpConnection: existing.hasLiveUdpConnection,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is PeerUdpConnectionChangedAction) {
    final existing = state.peers[action.pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(
        hasLiveUdpConnection: action.connected,
      );
      return state.copyWith(
        peers: Map.from(state.peers)..[action.pubkeyHex] = updated,
      );
    }
    return state;
  }

  if (action is PeerUdpDisconnectedAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      // If no other transport, mark as disconnected
      final newConnectionState = existing.hasBleConnection
          ? existing.connectionState
          : PeerConnectionState.disconnected;
      // Preserve UDP address — it's the last known location and needed
      // for reconnection. Never clear peer addresses.
      // Clear hasLiveUdpConnection — transport-level disconnect means no live stream.
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
        udpAddress: existing.udpAddress,  // Preserve for reconnection
        linkLocalAddress: existing.linkLocalAddress,
        isFriend: existing.isFriend,
        isWellConnected: existing.isWellConnected,
        hasLiveUdpConnection: false,
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
            udpAddress: peer.udpAddress,
            linkLocalAddress: peer.linkLocalAddress,
            isFriend: peer.isFriend,
            isWellConnected: peer.isWellConnected,
            hasLiveUdpConnection: peer.hasLiveUdpConnection,
          );
          return;
        }
      }

      if (peer.connectionState != PeerConnectionState.connected) return;
      if (peer.lastSeen == null) return;

      // Never mark a peer as stale if we have a live UDP connection to them.
      // The ANNOUNCE may have stopped arriving over BLE (e.g. BLE disabled),
      // but the UDP connection is still active and keeping the peer alive.
      if (action.liveUdpPeers.contains(key)) return;

      final timeSinceLastSeen = now.difference(peer.lastSeen!);
      if (timeSinceLastSeen > action.staleThreshold) {
        if (peer.isFriend) {
          // Friends are marked as disconnected when stale (no ANNOUNCE received).
          // Clear BLE IDs (out of BLE range) but preserve UDP address — it's
          // the last known location and needed for reconnection attempts.
          // Clearing it would make the peer unreachable, preventing signaling
          // and removing it from wellConnectedFriends.
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
            udpAddress: peer.udpAddress,  // Preserve for reconnection
            linkLocalAddress: peer.linkLocalAddress,
            isFriend: true,
            isWellConnected: peer.isWellConnected,
            hasLiveUdpConnection: peer.hasLiveUdpConnection,
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

  if (action is AssociateUdpAddressAction) {
    final pubkeyHex = _pubkeyToHex(action.publicKey);
    final existing = state.peers[pubkeyHex];
    if (existing != null) {
      final updated = existing.copyWith(
        udpAddress: action.address.isEmpty ? null : action.address,
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
      // (they were only reachable via UDP friendship)
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
        // Clear all UDP/friend fields
        isFriend: false,
        udpAddress: null,
        isWellConnected: false,
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
