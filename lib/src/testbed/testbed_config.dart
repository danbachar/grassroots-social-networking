import 'package:flutter/foundation.dart';

import '../models/identity.dart';

/// DEBUG/TESTBED ONLY. Config models for the two evaluation harnesses:
/// [NeighborAllowlist] (software-defined BLE topology) and [WorkloadConfig]
/// (deterministic offered load). Both are stored as nullable fields on
/// `SettingsState`, are inert/off by default, and must never affect
/// production behaviour. See `docs/testbed_case_studies.md`.

/// Force an arbitrary BLE topology by restricting which *immediate* BLE
/// neighbours this device may link with. The relayed wire envelope is
/// sender-anonymous, so we can only filter on the neighbour we received from —
/// which is exactly the adjacency edge in the topology graph.
@immutable
class NeighborAllowlist {
  /// When false, normal (production) behaviour — no filtering at all.
  final bool enabled;

  /// Lowercase hex-encoded *full* Ed25519 public keys (64 chars) of the only
  /// neighbours this device may form a BLE link with. Empty + enabled means
  /// "link with no one" (a fully partitioned node). Full keys are required
  /// (not prefixes) so the primary enforcement layer can derive each peer's
  /// rotating service UUID without an ANNOUNCE.
  final List<String> allow;

  const NeighborAllowlist({this.enabled = false, this.allow = const []});

  static const NeighborAllowlist disabled = NeighborAllowlist();

  /// Allowed pubkeys parsed to bytes (skips malformed entries).
  List<Uint8List> get _allowedPubkeys {
    final out = <Uint8List>[];
    for (final hex in allow) {
      final bytes = _hexToBytes(hex);
      if (bytes != null && bytes.length >= 32) out.add(bytes);
    }
    return out;
  }

  /// Whether a peer identified by [pubkey] is an allowed neighbour.
  bool allowsPubkey(Uint8List pubkey) => allowsPubkeyHex(
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join());

  bool allowsPubkeyHex(String pubkeyHex) {
    final target = pubkeyHex.toLowerCase();
    return allow.any((a) => target == a.toLowerCase());
  }

  /// Whether a discovered BLE [serviceUuid] derives to an allowed neighbour —
  /// the pre-ANNOUNCE check used to refuse a dial (Layer 1). Matches the
  /// current and adjacent rotation slots, like normal recognition.
  bool allowsServiceUuid(String serviceUuid) => _allowedPubkeys.any(
      (pk) => GrassrootsIdentity.serviceUuidMatchesPubkey(serviceUuid, pk));

  Map<String, dynamic> toJson() => {'enabled': enabled, 'allow': allow};

  factory NeighborAllowlist.fromJson(Map<String, dynamic> json) =>
      NeighborAllowlist(
        enabled: json['enabled'] as bool? ?? false,
        allow: (json['allow'] as List<dynamic>?)
                ?.map((e) => (e as String).toLowerCase())
                .toList() ??
            const [],
      );

  @override
  bool operator ==(Object other) =>
      other is NeighborAllowlist &&
      other.enabled == enabled &&
      listEquals(other.allow, allow);

  @override
  int get hashCode => Object.hash(enabled, Object.hashAll(allow));
}

/// One label→identity binding in the workload roster. The same roster file is
/// deployed to every device; a device finds its own row by matching
/// [pubkeyHex] against its identity.
@immutable
class WorkloadRosterEntry {
  final String label;
  final String pubkeyHex;

  const WorkloadRosterEntry({required this.label, required this.pubkeyHex});

  Map<String, dynamic> toJson() => {'label': label, 'pubkeyHex': pubkeyHex};

  factory WorkloadRosterEntry.fromJson(Map<String, dynamic> json) =>
      WorkloadRosterEntry(
        label: json['label'] as String,
        pubkeyHex: (json['pubkeyHex'] as String).toLowerCase(),
      );

  @override
  bool operator ==(Object other) =>
      other is WorkloadRosterEntry &&
      other.label == label &&
      other.pubkeyHex == pubkeyHex;

  @override
  int get hashCode => Object.hash(label, pubkeyHex);
}

/// A payload-size bucket for the workload's size mix.
@immutable
class WorkloadPayload {
  final int bytes;
  final double weight;

  const WorkloadPayload({required this.bytes, required this.weight});

  Map<String, dynamic> toJson() => {'bytes': bytes, 'weight': weight};

  factory WorkloadPayload.fromJson(Map<String, dynamic> json) =>
      WorkloadPayload(
        bytes: json['bytes'] as int,
        weight: (json['weight'] as num).toDouble(),
      );

  @override
  bool operator ==(Object other) =>
      other is WorkloadPayload && other.bytes == bytes && other.weight == weight;

  @override
  int get hashCode => Object.hash(bytes, weight);
}

/// Deterministic offered-load schedule. Every device computes the SAME full
/// schedule from [seed] + [roster] and executes only the rows where it is the
/// source, so the total scheduled count (across devices) is the reproducible
/// delivery-ratio denominator, computable offline from this config alone.
@immutable
class WorkloadConfig {
  final int seed;
  final int startAtEpochMs;
  final int endAtEpochMs;
  final List<WorkloadRosterEntry> roster;

  /// Seeded-Poisson mean rate per ORDERED pair (src→dst), messages per hour.
  final double ratePerPairPerHour;
  final List<WorkloadPayload> payloadMix;

  const WorkloadConfig({
    required this.seed,
    required this.startAtEpochMs,
    required this.endAtEpochMs,
    required this.roster,
    required this.ratePerPairPerHour,
    required this.payloadMix,
  });

  Map<String, dynamic> toJson() => {
        'seed': seed,
        'startAtEpochMs': startAtEpochMs,
        'endAtEpochMs': endAtEpochMs,
        'roster': roster.map((r) => r.toJson()).toList(),
        'ratePerPairPerHour': ratePerPairPerHour,
        'payloadMix': payloadMix.map((p) => p.toJson()).toList(),
      };

  factory WorkloadConfig.fromJson(Map<String, dynamic> json) => WorkloadConfig(
        seed: json['seed'] as int,
        startAtEpochMs: json['startAtEpochMs'] as int,
        endAtEpochMs: json['endAtEpochMs'] as int,
        roster: (json['roster'] as List<dynamic>)
            .map((e) => WorkloadRosterEntry.fromJson(e as Map<String, dynamic>))
            .toList(),
        ratePerPairPerHour: (json['ratePerPairPerHour'] as num).toDouble(),
        payloadMix: (json['payloadMix'] as List<dynamic>)
            .map((e) => WorkloadPayload.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  @override
  bool operator ==(Object other) =>
      other is WorkloadConfig &&
      other.seed == seed &&
      other.startAtEpochMs == startAtEpochMs &&
      other.endAtEpochMs == endAtEpochMs &&
      listEquals(other.roster, roster) &&
      other.ratePerPairPerHour == ratePerPairPerHour &&
      listEquals(other.payloadMix, payloadMix);

  @override
  int get hashCode => Object.hash(
        seed,
        startAtEpochMs,
        endAtEpochMs,
        Object.hashAll(roster),
        ratePerPairPerHour,
        Object.hashAll(payloadMix),
      );
}

Uint8List? _hexToBytes(String hex) {
  final clean = hex.trim().toLowerCase();
  if (clean.isEmpty || clean.length.isOdd) return null;
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
