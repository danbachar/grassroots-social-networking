import 'package:flutter/material.dart';

import 'grasslink_tokens.dart';

/// Peer mesh signal strength as growing bars — grasslink's signature
/// connectivity metaphor (design system `feedback/SignalMeter`). Strength is
/// 0–4; color steps rust → amber → moss, inactive bars are warm clay.
class SignalMeter extends StatelessWidget {
  final int strength;
  final int bars;
  final double unit;
  final bool showLabel;

  const SignalMeter({
    super.key,
    required this.strength,
    this.bars = 4,
    this.unit = 4,
    this.showLabel = false,
  });

  /// Map an RSSI measurement (dBm) to 0–4 bars. Null means "no measurement".
  factory SignalMeter.fromRssi(int? rssi, {double unit = 4, bool showLabel = false}) {
    final int strength;
    if (rssi == null) {
      strength = 0;
    } else if (rssi >= -55) {
      strength = 4;
    } else if (rssi >= -67) {
      strength = 3;
    } else if (rssi >= -80) {
      strength = 2;
    } else {
      strength = 1;
    }
    return SignalMeter(strength: strength, unit: unit, showLabel: showLabel);
  }

  static const _labels = ['No mesh', 'Weak', 'Fair', 'Strong', 'Excellent'];

  @override
  Widget build(BuildContext context) {
    final active = strength.clamp(0, bars);
    final color = active == 0
        ? GlColors.clay400
        : active <= 1
            ? GlColors.danger
            : active <= 2
                ? GlColors.warning
                : GlColors.success;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < bars; i++) ...[
              if (i > 0) SizedBox(width: unit / 2),
              AnimatedContainer(
                duration: GlMotion.normal,
                curve: GlMotion.easeOut,
                width: unit,
                height: unit * (i + 1),
                decoration: BoxDecoration(
                  color: i < active ? color : GlColors.clay200,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ],
        ),
        if (showLabel) ...[
          const SizedBox(width: GlSpace.s2),
          Text(
            _labels[active],
            style: const TextStyle(
              fontFamily: GlType.sans,
              fontSize: GlType.textSm,
              fontWeight: FontWeight.w500,
              color: GlColors.textMuted,
            ),
          ),
        ],
      ],
    );
  }
}

/// The terracotta "signal dot" — grasslink's minimal brand mark: a filled
/// circle with a soft concentric halo. Used beside the wordmark and as the
/// recurring decorative motif.
class SignalDot extends StatelessWidget {
  final double size;

  const SignalDot({super.key, this.size = 12});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: GlColors.terra400,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: GlColors.terra400.withValues(alpha: 0.3),
            spreadRadius: size * 0.3,
          ),
        ],
      ),
    );
  }
}

/// The grasslink wordmark: "grasslink" in the display face (always
/// lowercase) beside the [SignalDot].
class GrasslinkWordmark extends StatelessWidget {
  final double size;
  final Color color;
  final Color linkColor;

  const GrasslinkWordmark({
    super.key,
    this.size = GlType.textXl,
    this.color = GlColors.textStrong,
    this.linkColor = GlColors.primary,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SignalDot(size: size * 0.5),
        SizedBox(width: size * 0.45),
        Text.rich(
          TextSpan(
            style: GlType.displayStyle(size, color: color),
            children: [
              const TextSpan(text: 'grass'),
              TextSpan(text: 'link', style: TextStyle(color: linkColor)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Peer presence for [PeerAvatar]'s status dot: online (moss), relaying
/// (terracotta) — specific to a relay mesh — and offline (clay).
enum PeerPresence { online, relaying, offline }

/// Circular peer avatar with initials fallback and an optional presence dot
/// (design system `display/Avatar`). The fill tint is derived
/// deterministically from the name so a peer keeps their color.
class PeerAvatar extends StatelessWidget {
  final String name;
  final double size;
  final PeerPresence? presence;

  const PeerAvatar({
    super.key,
    required this.name,
    this.size = 48,
    this.presence,
  });

  static const _tints = [
    (GlColors.moss100, GlColors.moss700),
    (GlColors.terra100, GlColors.terra700),
    (GlColors.clay200, GlColors.clay700),
    (GlColors.infoSoft, GlColors.sky500),
    (GlColors.warningSoft, GlColors.amber500),
  ];

  @override
  Widget build(BuildContext context) {
    final initials = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .take(2)
        .map((w) => w[0].toUpperCase())
        .join();
    final (bg, fg) = _tints[name.hashCode.abs() % _tints.length];
    final dotColor = switch (presence) {
      PeerPresence.online => GlColors.success,
      PeerPresence.relaying => GlColors.terra400,
      PeerPresence.offline => GlColors.clay400,
      null => null,
    };

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(
              initials.isEmpty ? '·' : initials,
              style: TextStyle(
                fontFamily: GlType.sans,
                fontSize: size * 0.38,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ),
          if (dotColor != null)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: size * 0.28,
                height: size * 0.28,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: GlColors.surfaceCard, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Short all-caps micro-label ("eyebrow") — used sparingly per the voice
/// guide, e.g. `RELAYING FOR`, `SEND TO`.
class EyebrowLabel extends StatelessWidget {
  final String text;
  final Color color;

  const EyebrowLabel(this.text, {super.key, this.color = GlColors.textMuted});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontFamily: GlType.sans,
        fontSize: GlType.text2xs,
        fontWeight: FontWeight.w700,
        letterSpacing: GlType.trackingWide * GlType.text2xs * 2,
        color: color,
      ),
    );
  }
}
