import 'package:flutter/foundation.dart';
import '../transport/transport_service.dart';
import '../transport/address_utils.dart';

enum NetworkConnectionType {
  wifi,
  cellular,
  ethernet,
  vpn,
  other,
  offline,
}

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

/// Per-transport lifecycle state for Redux store.
///
/// Tracks the lifecycle state of each transport independently,
/// replacing the old single global `TransportConnectionStatus`.
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
  /// a hole-punch. This is empirical proof that our firewall and NAT path
  /// allow inbound packets at the claimed address.
  ///
  /// Bound to [publicAddress]: cleared whenever the address changes, since
  /// any prior proof was for a different network path.
  final DateTime? lastUnsolicitedInboundAt;

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
  });

  static const TransportsState initial = TransportsState();

  /// Whether any transport is active
  bool get isAnyActive =>
      bleState == TransportState.active || udpState == TransportState.active;

  /// Whether the system is in a healthy state (any transport active)
  bool get isHealthy => isAnyActive;

  /// Whether this device has a publicly routable address candidate.
  ///
  /// This means the address *looks* reachable, but we have no proof yet
  /// that unsolicited inbound actually works. Use [isWellConnected] for
  /// decisions where reachability matters.
  bool get hasPublicAddress =>
      publicAddress != null && isGloballyRoutableAddress(publicAddress!);

  /// Whether this device is verified well-connected: has a public address
  /// AND we have observed unsolicited inbound at that address.
  ///
  /// Only verified well-connected devices should advertise themselves as
  /// signaling facilitators. A device with a public address but no proof
  /// of inbound reachability may sit behind a stateful firewall that
  /// silently drops unsolicited packets — picking it as facilitator
  /// causes silent hole-punch failures.
  bool get isWellConnected =>
      hasPublicAddress && lastUnsolicitedInboundAt != null;

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
    );
  }

  /// Create a copy with publicAddress explicitly cleared (set to null).
  /// Keeps publicIp — the IP is still valid even if the full address isn't.
  /// Also clears lastUnsolicitedInboundAt — the proof was bound to the address.
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
    );
  }

  /// Create a copy with both publicAddress and publicIp cleared.
  /// Also clears lastUnsolicitedInboundAt — the proof was bound to the address.
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
    );
  }

  /// Create a copy with publicAddress changed to a new value, clearing the
  /// reachability proof (since the proof was bound to the previous address).
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
          lastUnsolicitedInboundAt == other.lastUnsolicitedInboundAt;

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
      );

  @override
  String toString() =>
      'TransportsState(ble: $bleState, udp: $udpState, scanning: $bleScanning, publicAddr: $publicAddress, publicIp: $publicIp, network: ${networkConnectionType.displayName}, wellConnected: $isWellConnected)';
}
