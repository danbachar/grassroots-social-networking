import 'package:flutter/foundation.dart';

/// Available transport protocols
enum TransportProtocol {
  bluetooth,
  udp,
}

/// Extension for display info
extension TransportProtocolDisplay on TransportProtocol {
  String get displayName {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Bluetooth';
      case TransportProtocol.udp:
        return 'Internet (UDP)';
    }
  }

  String get description {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Connect to nearby peers via Bluetooth Low Energy';
      case TransportProtocol.udp:
        return 'Connect to peers over the Internet via UDP';
    }
  }
}

/// Immutable transport settings for Redux store
@immutable
class SettingsState {
  /// Whether Bluetooth transport is enabled
  final bool bluetoothEnabled;

  /// Whether UDP Internet transport is enabled
  final bool udpEnabled;

  /// Priority order for transports (lower index = higher priority)
  /// Default: Bluetooth first, then UDP
  final List<TransportProtocol> transportPriority;

  /// Bootstrap anchor server address (e.g. "[2600:1234::1]:9514").
  /// Null means no anchor configured.
  ///
  /// The anchor's public key is not stored here — it is derived
  /// deterministically from the owner's identity at runtime.
  final String? anchorAddress;

  const SettingsState({
    this.bluetoothEnabled = true,
    this.udpEnabled = true,
    this.transportPriority = const [
      TransportProtocol.bluetooth,
      TransportProtocol.udp,
    ],
    this.anchorAddress,
  });

  static const SettingsState initial = SettingsState();

  /// Whether at least one transport is enabled
  bool get hasActiveTransport => bluetoothEnabled || udpEnabled;

  /// Get the preferred transport for sending messages
  TransportProtocol? get preferredTransport {
    for (final transport in transportPriority) {
      if (transport == TransportProtocol.bluetooth && bluetoothEnabled) {
        return TransportProtocol.bluetooth;
      }
      if (transport == TransportProtocol.udp && udpEnabled) {
        return TransportProtocol.udp;
      }
    }
    return null;
  }

  /// Whether an anchor server is configured.
  bool get hasAnchor => anchorAddress != null && anchorAddress!.isNotEmpty;

  SettingsState copyWith({
    bool? bluetoothEnabled,
    bool? udpEnabled,
    List<TransportProtocol>? transportPriority,
    // Use Object? + sentinel so callers can pass null to clear.
    Object? anchorAddress = _sentinel,
  }) {
    return SettingsState(
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      udpEnabled: udpEnabled ?? this.udpEnabled,
      transportPriority: transportPriority ?? this.transportPriority,
      anchorAddress: identical(anchorAddress, _sentinel)
          ? this.anchorAddress
          : anchorAddress as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'bluetoothEnabled': bluetoothEnabled,
        'udpEnabled': udpEnabled,
        'transportPriority': transportPriority.map((t) => t.name).toList(),
        'anchorAddress': anchorAddress,
      };

  factory SettingsState.fromJson(Map<String, dynamic> json) {
    return SettingsState(
      bluetoothEnabled: json['bluetoothEnabled'] as bool? ?? true,
      udpEnabled: json['udpEnabled'] as bool? ?? true,
      transportPriority: (json['transportPriority'] as List<dynamic>?)
              ?.map((e) => TransportProtocol.values.firstWhere(
                    (t) => t.name == e,
                    orElse: () => TransportProtocol.bluetooth,
                  ))
              .toList() ??
          const [TransportProtocol.bluetooth, TransportProtocol.udp],
      anchorAddress: json['anchorAddress'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsState &&
          runtimeType == other.runtimeType &&
          bluetoothEnabled == other.bluetoothEnabled &&
          udpEnabled == other.udpEnabled &&
          listEquals(transportPriority, other.transportPriority) &&
          anchorAddress == other.anchorAddress;

  @override
  int get hashCode => Object.hash(
        bluetoothEnabled,
        udpEnabled,
        Object.hashAll(transportPriority),
        anchorAddress,
      );

  @override
  String toString() =>
      'SettingsState(bt: $bluetoothEnabled, udp: $udpEnabled)';
}

/// Sentinel for copyWith — distinguishes "not passed" from "passed null".
const _sentinel = Object();
