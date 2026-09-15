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

  /// Ring-radius experiment: the roster of participating pubkeys, in RING
  /// ORDER — lowercase hex, sorted ascending, de-duplicated.
  ///
  /// The sort IS the ring (see `testbed/ring_topology.dart`): ordering by
  /// pubkey is what lets every phone derive the same ring from the same roster
  /// with no coordination and no assigned positions. Normalisation is applied
  /// by the reducer — the only write path — so ring order is an invariant of
  /// the state rather than a property of whoever supplied the list.
  ///
  /// Empty in production, which leaves [ringRadius] nothing to constrain.
  final List<String> ringRoster;

  /// Ring-radius experiment: the greatest ring distance a BLE link may span.
  ///
  /// **Null means the gate is not armed** — the production value, and also the
  /// state the operator warms the mesh up in, where every pair has to be able
  /// to handshake.
  ///
  /// NOT persisted, and neither is [ringRoster]: a radius that survives a
  /// restart arms the gate before warm-up, so non-neighbours never handshake,
  /// the session table comes up short and [FieldPlan.ringSize] refuses to
  /// launch. The gate is armed by a running step and disarmed when the run
  /// ends; a process restart lands in the same disarmed state.
  ///
  /// It lives here beside [coldCallTrustLevel], not in `TransportsState`,
  /// because it is POLICY: Redux transport state is a strict projection of
  /// facts the transports report, never an input to them.
  final int? ringRadius;

  /// Testbed ignore list: pubkeys (lowercase hex) of phones in the room that
  /// are not part of the experiment.
  ///
  /// The ring roster is derived from the session table, so a phone that is
  /// merely in range joins the ring by pairing. An ignored phone is refused
  /// at every point identity is known — its ANNOUNCE, its handshake and its
  /// links — and is left out of the session table the roster is read from.
  ///
  /// NOT persisted, like [ringRadius]: a list that came back from disk would
  /// silently shrink the next full-fleet run.
  final Set<String> ignoredPeerHexes;

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
    this.ringRoster = const [],
    this.ringRadius,
    this.ignoredPeerHexes = const {},
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
    List<String>? ringRoster,
    // Use Object? + sentinel so callers can pass null to clear.
    Object? ringRadius = _unset,
    Set<String>? ignoredPeerHexes,
  }) {
    return SettingsState(
      bluetoothEnabled: bluetoothEnabled ?? this.bluetoothEnabled,
      udpEnabled: udpEnabled ?? this.udpEnabled,
      transportPriority: transportPriority ?? this.transportPriority,
      bleRoleMode: bleRoleMode ?? this.bleRoleMode,
      coldCallTrustLevel: coldCallTrustLevel ?? this.coldCallTrustLevel,
      facilitateInvites: facilitateInvites ?? this.facilitateInvites,
      showLinkDiagnostics: showLinkDiagnostics ?? this.showLinkDiagnostics,
      ringRoster: ringRoster ?? this.ringRoster,
      // Disarming the gate is `ringRadius: null`, which is why this one needs
      // the sentinel: "not passed" and "passed null" mean opposite things.
      ringRadius:
          identical(ringRadius, _unset) ? this.ringRadius : ringRadius as int?,
      ignoredPeerHexes: ignoredPeerHexes ?? this.ignoredPeerHexes,
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
      // The ring gate is deliberately absent: hydration always disarms it.
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
          showLinkDiagnostics == other.showLinkDiagnostics &&
          listEquals(ringRoster, other.ringRoster) &&
          ringRadius == other.ringRadius &&
          setEquals(ignoredPeerHexes, other.ignoredPeerHexes);

  @override
  int get hashCode => Object.hash(
        bluetoothEnabled,
        udpEnabled,
        Object.hashAll(transportPriority),
        bleRoleMode,
        coldCallTrustLevel,
        facilitateInvites,
        showLinkDiagnostics,
        Object.hashAll(ringRoster),
        ringRadius,
        Object.hashAllUnordered(ignoredPeerHexes),
      );

  @override
  String toString() =>
      'SettingsState(bt: $bluetoothEnabled, udp: $udpEnabled)';
}

/// Sentinel for copyWith — distinguishes "not passed" from "passed null".
const Object _unset = Object();
