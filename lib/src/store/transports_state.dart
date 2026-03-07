import 'package:flutter/foundation.dart';
import '../transport/transport_service.dart';

/// Per-transport lifecycle state for Redux store.
///
/// Tracks the lifecycle state of each transport independently,
/// replacing the old single global `TransportConnectionStatus`.
@immutable
class TransportsState {
  /// BLE transport lifecycle state
  final TransportState bleState;

  /// LibP2P transport lifecycle state
  final TransportState libp2pState;

  /// Error message for BLE transport (if in error state)
  final String? bleError;

  /// Error message for libp2p transport (if in error state)
  final String? libp2pError;

  /// Whether BLE is currently scanning
  final bool bleScanning;

  const TransportsState({
    this.bleState = TransportState.uninitialized,
    this.libp2pState = TransportState.uninitialized,
    this.bleError,
    this.libp2pError,
    this.bleScanning = false,
  });

  static const TransportsState initial = TransportsState();

  /// Whether any transport is active
  bool get isAnyActive =>
      bleState == TransportState.active ||
      libp2pState == TransportState.active;

  /// Whether the system is in a healthy state (any transport active)
  bool get isHealthy => isAnyActive;

  /// Overall status display string derived from per-transport states
  String get statusDisplayString {
    if (isAnyActive) {
      if (bleScanning) return 'Scanning for peers...';
      return 'Online';
    }
    if (bleState == TransportState.initializing ||
        libp2pState == TransportState.initializing) {
      return 'Starting...';
    }
    if (bleState == TransportState.ready ||
        libp2pState == TransportState.ready) {
      return 'Ready';
    }
    if (bleState == TransportState.error ||
        libp2pState == TransportState.error) {
      return bleError ?? libp2pError ?? 'Error';
    }
    return 'Initializing...';
  }

  TransportsState copyWith({
    TransportState? bleState,
    TransportState? libp2pState,
    String? bleError,
    String? libp2pError,
    bool? bleScanning,
  }) {
    return TransportsState(
      bleState: bleState ?? this.bleState,
      libp2pState: libp2pState ?? this.libp2pState,
      bleError: bleError ?? this.bleError,
      libp2pError: libp2pError ?? this.libp2pError,
      bleScanning: bleScanning ?? this.bleScanning,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransportsState &&
          runtimeType == other.runtimeType &&
          bleState == other.bleState &&
          libp2pState == other.libp2pState &&
          bleError == other.bleError &&
          libp2pError == other.libp2pError &&
          bleScanning == other.bleScanning;

  @override
  int get hashCode => Object.hash(
        bleState,
        libp2pState,
        bleError,
        libp2pError,
        bleScanning,
      );

  @override
  String toString() =>
      'TransportsState(ble: $bleState, libp2p: $libp2pState, scanning: $bleScanning)';
}
