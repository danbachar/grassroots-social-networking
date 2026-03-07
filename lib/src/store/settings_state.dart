import 'package:flutter/foundation.dart';

/// Available transport protocols
enum TransportProtocol {
  bluetooth,
  libp2p,
}

/// Extension for display info
extension TransportProtocolDisplay on TransportProtocol {
  String get displayName {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Bluetooth';
      case TransportProtocol.libp2p:
        return 'Internet (libp2p)';
    }
  }

  String get description {
    switch (this) {
      case TransportProtocol.bluetooth:
        return 'Connect to nearby peers via Bluetooth Low Energy';
      case TransportProtocol.libp2p:
        return 'Connect to peers over the Internet';
    }
  }
}

/// Immutable transport settings for Redux store
@immutable
class SettingsState {
  /// Whether Bluetooth transport is enabled
  final bool bluetoothEnabled;

  /// Whether libp2p Internet transport is enabled
  final bool libp2pEnabled;

  /// Priority order for transports (lower index = higher priority)
  /// Default: Bluetooth first, then libp2p
  final List<TransportProtocol> transportPriority;

  const SettingsState({
    this.bluetoothEnabled = true,
    this.libp2pEnabled = true,
    this.transportPriority = const [
      TransportProtocol.bluetooth,
      TransportProtocol.libp2p,
    ],
  });

  static const SettingsState initial = SettingsState();

  /// Whether at least one transport is enabled
  bool get hasActiveTransport => bluetoothEnabled || libp2pEnabled;

  /// Get the preferred transport for sending messages
  TransportProtocol? get preferredTransport {
    for (final transport in transportPriority) {
      if (transport == TransportProtocol.bluetooth && bluetoothEnabled) {
        return TransportProtocol.bluetooth;
      }
      if (transport == TransportProtocol.libp2p && libp2pEnabled) {
        return TransportProtocol.libp2p;
      }
    }
    return null;
  }

  SettingsState copyWith({
    bool? bluetoothEnabled,
    bool? libp2pEnabled,
    List<TransportProtocol>? transportPriority,
  }) {
    return SettingsState(
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      libp2pEnabled: libp2pEnabled ?? this.libp2pEnabled,
      transportPriority: transportPriority ?? this.transportPriority,
    );
  }

  Map<String, dynamic> toJson() => {
        'bluetoothEnabled': bluetoothEnabled,
        'libp2pEnabled': libp2pEnabled,
        'transportPriority': transportPriority.map((t) => t.name).toList(),
      };

  factory SettingsState.fromJson(Map<String, dynamic> json) {
    return SettingsState(
      bluetoothEnabled: json['bluetoothEnabled'] as bool? ?? true,
      libp2pEnabled: json['libp2pEnabled'] as bool? ?? true,
      transportPriority: (json['transportPriority'] as List<dynamic>?)
              ?.map((e) => TransportProtocol.values.firstWhere(
                    (t) => t.name == e,
                    orElse: () => TransportProtocol.bluetooth,
                  ))
              .toList() ??
          const [TransportProtocol.bluetooth, TransportProtocol.libp2p],
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SettingsState &&
          runtimeType == other.runtimeType &&
          bluetoothEnabled == other.bluetoothEnabled &&
          libp2pEnabled == other.libp2pEnabled &&
          listEquals(transportPriority, other.transportPriority);

  @override
  int get hashCode => Object.hash(
        bluetoothEnabled,
        libp2pEnabled,
        Object.hashAll(transportPriority),
      );

  @override
  String toString() =>
      'SettingsState(bt: $bluetoothEnabled, libp2p: $libp2pEnabled)';
}
