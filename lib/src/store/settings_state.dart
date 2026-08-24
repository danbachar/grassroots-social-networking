import 'package:flutter/foundation.dart';


/// Available transport protocols
enum TransportProtocol {
  bluetooth,
  udp,
}

/// Debug knob: which BLE roles this device should run.
///
/// In production both roles are always on (`auto`) so peer discovery is
/// symmetric. The other modes exist so a developer can deterministically
/// produce asymmetric topologies for testing — e.g. force one device to be
/// peripheral-only and confirm the consumer falls back to the peripheral
/// path for outbound sends.
enum BleRoleMode {
  /// Scan AND advertise (default; produces both central and peripheral paths).
  auto,

  /// Scan only — never advertise. Peers won't dial us, so we'll only ever
  /// have `central:*` paths.
  centralOnly,

  /// Advertise only — never scan. We won't dial peers, so we'll only ever
  /// have `peripheral:*` paths.
  peripheralOnly,
}

/// Policy for unsolicited first contact from peers that do not already have
/// an accepted relationship with us.
enum ColdCallTrustLevel {
  /// Complete BLE ANNOUNCE with nearby strangers and allow first contact.
  open,

  /// Do not complete BLE ANNOUNCE with unknown nearby peers.
  closed,
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

  /// Which BLE roles this device should run. Default `auto`.
  final BleRoleMode bleRoleMode;

  /// Whether unsolicited nearby BLE peers may complete first-contact ANNOUNCE.
  final ColdCallTrustLevel coldCallTrustLevel;

  /// Whether this device volunteers to **introduce strangers** — coordinate a
  /// first-contact hole-punch for an invitee redeeming an invite one of our
  /// friends issued. A deliberate privacy choice, never auto-enabled and
  /// AND-gated by [coldCallTrustLevel] (see [willingToFacilitateInvites]):
  /// introducing strangers is a strictly more-open stance than accepting
  /// cold calls, so you cannot do it while closed to cold calls.
  final bool facilitateInvites;

  /// Debug: overlay ground-truth BLE link (ACL) counts in the UI — total on
  /// the chat screen and a per-peer count on peer rows. Data comes from the
  /// plugin's OS-level link snapshot, not the app's path bookkeeping.
  final bool showLinkDiagnostics;

  // ===== Testbed harnesses (debug-only; null/off in production) =====


  const SettingsState({
    this.bluetoothEnabled = true,
    this.udpEnabled = true,
    this.transportPriority = const [
      TransportProtocol.bluetooth,
      TransportProtocol.udp,
    ],
    this.bleRoleMode = BleRoleMode.auto,
    this.coldCallTrustLevel = ColdCallTrustLevel.open,
    this.facilitateInvites = false,
    this.showLinkDiagnostics = false,
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

  /// Effective willingness to introduce strangers: the opt-in toggle AND an
  /// open cold-call posture (introducing is strictly more open than accepting
  /// cold calls). The UI disables the toggle while cold-call is closed, but
  /// this getter is the authority the transport layer consults.
  bool get willingToFacilitateInvites =>
      facilitateInvites && coldCallTrustLevel == ColdCallTrustLevel.open;

  SettingsState copyWith({
    bool? bluetoothEnabled,
    bool? udpEnabled,
    List<TransportProtocol>? transportPriority,
    BleRoleMode? bleRoleMode,
    ColdCallTrustLevel? coldCallTrustLevel,
    bool? facilitateInvites,
    bool? showLinkDiagnostics,
    // Use Object? + sentinel so callers can pass null to clear.
  }) {
    return SettingsState(
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      udpEnabled: udpEnabled ?? this.udpEnabled,
      transportPriority: transportPriority ?? this.transportPriority,
      bleRoleMode: bleRoleMode ?? this.bleRoleMode,
      coldCallTrustLevel: coldCallTrustLevel ?? this.coldCallTrustLevel,
      facilitateInvites: facilitateInvites ?? this.facilitateInvites,
      showLinkDiagnostics: showLinkDiagnostics ?? this.showLinkDiagnostics,
    );
  }

  Map<String, dynamic> toJson() => {
        'bluetoothEnabled': bluetoothEnabled,
        'udpEnabled': udpEnabled,
        'transportPriority': transportPriority.map((t) => t.name).toList(),
        'bleRoleMode': bleRoleMode.name,
        'coldCallTrustLevel': coldCallTrustLevel.name,
        'facilitateInvites': facilitateInvites,
        'showLinkDiagnostics': showLinkDiagnostics,
      };

  factory SettingsState.fromJson(Map<String, dynamic> json) {
    final roleModeName = json['bleRoleMode'] as String?;
    final bleRoleMode = BleRoleMode.values.firstWhere(
      (m) => m.name == roleModeName,
      orElse: () => BleRoleMode.auto,
    );
    final trustLevelName = json['coldCallTrustLevel'] as String?;
    final coldCallTrustLevel = ColdCallTrustLevel.values.firstWhere(
      (level) => level.name == trustLevelName,
      orElse: () => ColdCallTrustLevel.closed,
    );

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
      bleRoleMode: bleRoleMode,
      coldCallTrustLevel: coldCallTrustLevel,
      facilitateInvites: json['facilitateInvites'] as bool? ?? false,
      showLinkDiagnostics: json['showLinkDiagnostics'] as bool? ?? false,
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
          bleRoleMode == other.bleRoleMode &&
          coldCallTrustLevel == other.coldCallTrustLevel &&
          facilitateInvites == other.facilitateInvites &&
          showLinkDiagnostics == other.showLinkDiagnostics;

  @override
  int get hashCode => Object.hash(
        bluetoothEnabled,
        udpEnabled,
        Object.hashAll(transportPriority),
        bleRoleMode,
        coldCallTrustLevel,
        facilitateInvites,
        showLinkDiagnostics,
      );

  @override
  String toString() =>
      'SettingsState(bt: $bluetoothEnabled, udp: $udpEnabled)';
}

/// Sentinel for copyWith — distinguishes "not passed" from "passed null".
