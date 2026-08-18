import 'package:flutter/foundation.dart';
import '../transport/transport_service.dart';
import '../transport/address_utils.dart';

enum NetworkConnectionType { wifi, cellular, ethernet, vpn, other, offline }

extension NetworkConnectionTypeX on NetworkConnectionType {
  String get displayName {
    switch (this) {
      case NetworkConnectionType.wifi:
        return 'Wi-Fi';
      case NetworkConnectionType.cellular:
        return 'Cellular';
      case NetworkConnectionType.ethernet:
        return 'Ethernet';
      case NetworkConnectionType.vpn:
        return 'VPN';
      case NetworkConnectionType.other:
        return 'Other';
      case NetworkConnectionType.offline:
        return 'Offline';
    }
  }
}

/// One live physical BLE link (ACL) as reported by the plugin's OS-level
/// snapshot — a strict projection of a transport fact. [address] matches the
/// address part of path IDs (`central:X` / `peripheral:X`), so peers are
/// joined to links by address. An entry with both roles is one shared link
/// carrying both GATT directions (over-ACL); two entries mapping to the same
/// peer mean a dual-ACL pair.
@immutable
class BleLinkDiagnostic {
  final String address;
  final bool clientRole;
  final bool serverRole;

  const BleLinkDiagnostic({
    required this.address,
    required this.clientRole,
    required this.serverRole,
  });

  @override
  bool operator ==(Object other) =>
      other is BleLinkDiagnostic &&
      other.address == address &&
      other.clientRole == clientRole &&
      other.serverRole == serverRole;

  @override
  int get hashCode => Object.hash(address, clientRole, serverRole);
}

/// What a peer's live BLE connection is made of.
@immutable
class BleLinkTally {
  /// GATT directions in use across the pair's links. This is the number that
  /// says whether a pair has converged: 2 is dual-role, 1 is a half-open pair
  /// still trying to complete.
  final int legs;

  /// Physical ACL connections the pair holds. Usually 1 even when converged,
  /// because both GATT directions ride one ACL; 2 only when the peer presents
  /// a different address for each direction.
  final int acls;

  const BleLinkTally({required this.legs, required this.acls});

  bool get isDualRole => legs >= 2;
}

/// Split the OS-level link snapshot for one peer into legs and ACLs, matching
/// its live path IDs (`central:X` / `peripheral:X`; nulls skipped) by address.
///
/// Counting entries alone cannot answer the question the diagnostics exist to
/// answer. A pair's two GATT directions normally share one ACL and one remote
/// address, so an address-keyed count reads 1 whether the pair has converged
/// to dual-role or is holding a single leg — the two states it most matters to
/// tell apart. The snapshot already distinguishes them: each entry carries the
/// roles riding that link, so the legs are summed from those flags and the
/// ACLs are the entries themselves.
BleLinkTally bleLinkTallyForPathIds(
    List<BleLinkDiagnostic> links, Iterable<String?> pathIds) {
  final addrs = pathIds
      .whereType<String>()
      .map((id) => id.substring(id.indexOf(':') + 1))
      .toSet();
  if (addrs.isEmpty) return const BleLinkTally(legs: 0, acls: 0);
  final mine = links.where((l) => addrs.contains(l.address)).toList();
  var legs = 0;
  for (final l in mine) {
    if (l.clientRole) legs++;
    if (l.serverRole) legs++;
  }
  return BleLinkTally(legs: legs, acls: mine.length);
}

/// Per-transport lifecycle state for Redux store.
///
/// Tracks the lifecycle state of each transport independently, rather than
/// through one global connection status.
@immutable
class TransportsState {
  /// BLE transport lifecycle state
  final TransportState bleState;

  /// UDP transport lifecycle state
  final TransportState udpState;

  /// Error message for BLE transport (if in error state)
  final String? bleError;

  /// Error message for UDP transport (if in error state)
  final String? udpError;

  /// Whether BLE is currently scanning
  final bool bleScanning;

  /// Our discovered public UDP address (ip:port), null if not yet discovered
  final String? publicAddress;

  /// Our public IP address (no port), for display purposes.
  /// Set even when behind NAT. Updated by seeip.org discovery and friend
  /// reflection. IPv6-only.
  final String? publicIp;

  /// The current IP network type used for Internet connectivity.
  final NetworkConnectionType networkConnectionType;

  /// When we last observed unsolicited inbound traffic at [publicAddress]
  /// — i.e. a peer connected to us via UDP without us first coordinating
  /// a hole-punch.
  ///
  /// Bound to [publicAddress]: cleared whenever the address changes, since
  /// any prior observation was for a different network path.
  final DateTime? lastUnsolicitedInboundAt;

  /// True when the most recent public address discovery attempt finished
  /// without producing an address AND no friend/RV reflection has filled
  /// one in either. Cleared automatically as soon as a public address or
  /// reflected IP arrives, or when a new discovery attempt is in flight.
  final bool publicAddressDiscoveryFailed;

  /// Latest OS-level BLE link snapshot (debug diagnostics; empty unless the
  /// showLinkDiagnostics setting has the poll running).
  final List<BleLinkDiagnostic> bleLinks;

  const TransportsState({
    this.bleState = TransportState.uninitialized,
    this.udpState = TransportState.uninitialized,
    this.bleError,
    this.udpError,
    this.bleScanning = false,
    this.publicAddress,
    this.publicIp,
    this.networkConnectionType = NetworkConnectionType.offline,
    this.lastUnsolicitedInboundAt,
    this.publicAddressDiscoveryFailed = false,
    this.bleLinks = const [],
  });

  static const TransportsState initial = TransportsState();

  /// Whether any transport is active
  bool get isAnyActive =>
      bleState == TransportState.active || udpState == TransportState.active;

  /// Whether the system is in a healthy state (any transport active)
  bool get isHealthy => isAnyActive;

  /// Whether this device has a publicly routable address.
  bool get hasPublicAddress =>
      publicAddress != null && isGloballyRoutableAddress(publicAddress!);

  /// Whether this device is well-connected: it has a globally routable UDP
  /// address and can advertise itself as a signaling facilitator.
  bool get isWellConnected => hasPublicAddress;

  /// Overall status display string derived from per-transport states
  String get statusDisplayString {
    if (isAnyActive) {
      if (bleScanning) return 'Scanning for peers...';
      return 'Online';
    }
    if (bleState == TransportState.initializing ||
        udpState == TransportState.initializing) {
      return 'Starting...';
    }
    if (bleState == TransportState.ready || udpState == TransportState.ready) {
      return 'Ready';
    }
    if (bleState == TransportState.error || udpState == TransportState.error) {
      return bleError ?? udpError ?? 'Error';
    }
    return 'Initializing...';
  }

  TransportsState copyWith({
    TransportState? bleState,
    TransportState? udpState,
    String? bleError,
    String? udpError,
    bool? bleScanning,
    String? publicAddress,
    String? publicIp,
    NetworkConnectionType? networkConnectionType,
    DateTime? lastUnsolicitedInboundAt,
    bool? publicAddressDiscoveryFailed,
    List<BleLinkDiagnostic>? bleLinks,
  }) {
    return TransportsState(
      bleState: bleState ?? this.bleState,
      udpState: udpState ?? this.udpState,
      bleError: bleError ?? this.bleError,
      udpError: udpError ?? this.udpError,
      bleScanning: bleScanning ?? this.bleScanning,
      publicAddress: publicAddress ?? this.publicAddress,
      publicIp: publicIp ?? this.publicIp,
      networkConnectionType:
          networkConnectionType ?? this.networkConnectionType,
      lastUnsolicitedInboundAt:
          lastUnsolicitedInboundAt ?? this.lastUnsolicitedInboundAt,
      publicAddressDiscoveryFailed:
          publicAddressDiscoveryFailed ?? this.publicAddressDiscoveryFailed,
      bleLinks: bleLinks ?? this.bleLinks,
    );
  }

  /// Create a copy with publicAddress explicitly cleared (set to null).
  /// Keeps publicIp — the IP is still valid even if the full address isn't.
  /// Also clears lastUnsolicitedInboundAt because it was bound to the address.
  TransportsState clearPublicAddress() {
    return TransportsState(
      bleState: bleState,
      udpState: udpState,
      bleError: bleError,
      udpError: udpError,
      bleScanning: bleScanning,
      publicAddress: null,
      publicIp: publicIp,
      networkConnectionType: networkConnectionType,
      lastUnsolicitedInboundAt: null,
      publicAddressDiscoveryFailed: publicAddressDiscoveryFailed,
      bleLinks: bleLinks,
    );
  }

  /// Create a copy with both publicAddress and publicIp cleared.
  /// Also clears lastUnsolicitedInboundAt because it was bound to the address.
  TransportsState clearPublicConnectivity() {
    return TransportsState(
      bleState: bleState,
      udpState: udpState,
      bleError: bleError,
      udpError: udpError,
      bleScanning: bleScanning,
      publicAddress: null,
      publicIp: null,
      networkConnectionType: networkConnectionType,
      lastUnsolicitedInboundAt: null,
      publicAddressDiscoveryFailed: publicAddressDiscoveryFailed,
      bleLinks: bleLinks,
    );
  }

  /// Create a copy with publicAddress changed to a new value, clearing the
  /// reachability observation because it was bound to the previous address.
  /// Also clears the discovery-failed flag — we now have an address.
  TransportsState withNewPublicAddress(String address) {
    return TransportsState(
      bleState: bleState,
      udpState: udpState,
      bleError: bleError,
      udpError: udpError,
      bleScanning: bleScanning,
      publicAddress: address,
      publicIp: publicIp,
      networkConnectionType: networkConnectionType,
      lastUnsolicitedInboundAt: null,
      publicAddressDiscoveryFailed: false,
      bleLinks: bleLinks,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportsState &&
          runtimeType == other.runtimeType &&
          bleState == other.bleState &&
          udpState == other.udpState &&
          bleError == other.bleError &&
          udpError == other.udpError &&
          bleScanning == other.bleScanning &&
          publicAddress == other.publicAddress &&
          publicIp == other.publicIp &&
          networkConnectionType == other.networkConnectionType &&
          lastUnsolicitedInboundAt == other.lastUnsolicitedInboundAt &&
          publicAddressDiscoveryFailed == other.publicAddressDiscoveryFailed &&
          listEquals(bleLinks, other.bleLinks);

  @override
  int get hashCode => Object.hash(
    bleState,
    udpState,
    bleError,
    udpError,
    bleScanning,
    publicAddress,
    publicIp,
    networkConnectionType,
    lastUnsolicitedInboundAt,
    publicAddressDiscoveryFailed,
    Object.hashAll(bleLinks),
  );

  @override
  String toString() =>
      'TransportsState(ble: $bleState, udp: $udpState, scanning: $bleScanning, publicAddr: $publicAddress, publicIp: $publicIp, network: ${networkConnectionType.displayName}, wellConnected: $isWellConnected, discoveryFailed: $publicAddressDiscoveryFailed)';
}
