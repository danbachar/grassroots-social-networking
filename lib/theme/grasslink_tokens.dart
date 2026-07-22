import 'package:flutter/material.dart';

/// grasslink design tokens — warm, earthy, humane.
///
/// Direct port of the design system's token files
/// (`grasslink_handoff/design-system/tokens/*.css`). Product code references
/// these tokens (usually via [Theme] / `GrasslinkTheme`) — never hardcoded
/// hex values. Page background is warm cream ([GlColors.bgPage]), never pure
/// white; text is warm dark clay, never pure black.
abstract final class GlColors {
  // Clay — warm neutral ramp (the "earth" the brand sits on).
  static const clay50 = Color(0xFFFBF6EE);
  static const clay100 = Color(0xFFF4EDE1);
  static const clay200 = Color(0xFFE9DBC7);
  static const clay300 = Color(0xFFD9C6AC);
  static const clay400 = Color(0xFFBCA684);
  static const clay500 = Color(0xFF94805F);
  static const clay600 = Color(0xFF6E5C41);
  static const clay700 = Color(0xFF4F4130);
  static const clay800 = Color(0xFF3A2E24);
  static const clay900 = Color(0xFF241C15);

  // Moss — primary. Grass, growth, connection.
  static const moss50 = Color(0xFFEFF2E5);
  static const moss100 = Color(0xFFDCE4C4);
  static const moss200 = Color(0xFFBFCB95);
  static const moss300 = Color(0xFFA1B067);
  static const moss400 = Color(0xFF849449);
  static const moss500 = Color(0xFF6B7B37);
  static const moss600 = Color(0xFF55632B);
  static const moss700 = Color(0xFF414C22);
  static const moss800 = Color(0xFF2F3819);
  static const moss900 = Color(0xFF1E2410);

  // Terracotta — secondary accent. Warmth, people, signal.
  static const terra50 = Color(0xFFFBEDE4);
  static const terra100 = Color(0xFFF6D8C5);
  static const terra200 = Color(0xFFEDB79A);
  static const terra300 = Color(0xFFE1926D);
  static const terra400 = Color(0xFFD2703F);
  static const terra500 = Color(0xFFBE5A2C);
  static const terra600 = Color(0xFF9E4622);
  static const terra700 = Color(0xFF79351A);
  static const terra800 = Color(0xFF572514);
  static const terra900 = Color(0xFF38180D);

  // Semantic hues.
  static const amber400 = Color(0xFFE0A93B);
  static const amber500 = Color(0xFFD08E1E);
  static const sky400 = Color(0xFF4E8C84);
  static const sky500 = Color(0xFF3F7C74);
  static const rust400 = Color(0xFFCE5340);
  static const rust500 = Color(0xFFB8402D);

  // ---- Semantic aliases (use these in product code) ----
  static const bgPage = clay50;
  static const bgSunken = clay100;
  static const surfaceCard = Color(0xFFFFFFFF);
  static const surfaceInset = clay100;
  static const surfaceInverse = clay800;

  static const textStrong = clay900;
  static const textBody = clay800;
  static const textMuted = clay600;
  static const textSubtle = clay500;
  static const textInverse = clay50;
  static const textOnPrimary = Color(0xFFFFFFFF);

  static const borderSubtle = clay200;
  static const borderDefault = clay300;
  static const borderStrong = clay400;

  static const primary = moss500;
  static const primaryHover = moss600;
  static const primaryActive = moss700;
  static const primarySoft = moss100;
  static const primaryOnSoft = moss700;

  static const accent = terra500;
  static const accentHover = terra600;
  static const accentActive = terra700;
  static const accentSoft = terra100;
  static const accentOnSoft = terra700;

  static const success = moss500;
  static const successSoft = moss100;
  static const warning = amber500;
  static const warningSoft = Color(0xFFF7E7C4);
  static const danger = rust500;
  static const dangerSoft = Color(0xFFF5D8D2);
  static const info = sky500;
  static const infoSoft = Color(0xFFD5E5E3);

  static const focusRing = terra400;

  /// Warm shadow tint — every elevation uses this, never pure black.
  static const shadowTint = clay800; // rgba(58,46,36,…)

  /// Modal scrim — translucent warm clay.
  static const scrim = Color(0x73241C15); // rgba(36,28,21,.45)
}

/// grasslink typography — Bricolage Grotesque (display), Hanken Grotesk
/// (text), JetBrains Mono (mono). Families are bundled in `assets/fonts/`.
abstract final class GlType {
  static const display = 'Bricolage Grotesque';
  static const sans = 'Hanken Grotesk';
  static const mono = 'JetBrains Mono';

  // Type scale (px).
  static const double text2xs = 11;
  static const double textXs = 12;
  static const double textSm = 14;
  static const double textMd = 16;
  static const double textLg = 18;
  static const double textXl = 22;
  static const double text2xl = 28;
  static const double text3xl = 36;
  static const double text4xl = 48;
  static const double text5xl = 64;

  // Tracking (em → multiply by font size for Flutter's letterSpacing).
  static const double trackingTight = -0.02;
  static const double trackingSnug = -0.01;
  static const double trackingWide = 0.04;

  /// Display style: Bricolage, extrabold, tight tracking.
  static TextStyle displayStyle(double size,
          {FontWeight weight = FontWeight.w800, Color color = GlColors.textStrong}) =>
      TextStyle(
        fontFamily: display,
        fontSize: size,
        fontWeight: weight,
        letterSpacing: trackingTight * size,
        height: 1.1,
        color: color,
      );

  /// Mono style: JetBrains Mono for relay keys, node IDs, addresses, logs.
  static TextStyle monoStyle(double size,
          {FontWeight weight = FontWeight.w400, Color color = GlColors.textBody}) =>
      TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: weight,
        height: 1.5,
        color: color,
      );
}

/// grasslink spacing — 4px base rhythm.
abstract final class GlSpace {
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double s7 = 48;
  static const double s8 = 64;
  static const double s9 = 96;
}

/// grasslink radii — generously rounded, organic corners. Nothing sharp.
abstract final class GlRadius {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;
  static const double xxl = 36;
  static const double pill = 999;

  static BorderRadius get rXs => BorderRadius.circular(xs);
  static BorderRadius get rSm => BorderRadius.circular(sm);
  static BorderRadius get rMd => BorderRadius.circular(md);
  static BorderRadius get rLg => BorderRadius.circular(lg);
  static BorderRadius get rXl => BorderRadius.circular(xl);
  static BorderRadius get rPill => BorderRadius.circular(pill);
}

/// grasslink elevation — soft, warm-tinted shadows (never pure black).
abstract final class GlShadows {
  static List<BoxShadow> get xs => [
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.06),
            offset: const Offset(0, 1),
            blurRadius: 2),
      ];
  static List<BoxShadow> get sm => [
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.08),
            offset: const Offset(0, 1),
            blurRadius: 3),
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.05),
            offset: const Offset(0, 1),
            blurRadius: 2),
      ];
  static List<BoxShadow> get md => [
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.10),
            offset: const Offset(0, 4),
            blurRadius: 12),
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.06),
            offset: const Offset(0, 2),
            blurRadius: 4),
      ];
  static List<BoxShadow> get lg => [
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.14),
            offset: const Offset(0, 12),
            blurRadius: 28),
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.06),
            offset: const Offset(0, 4),
            blurRadius: 8),
      ];
  static List<BoxShadow> get xl => [
        BoxShadow(
            color: GlColors.shadowTint.withValues(alpha: 0.18),
            offset: const Offset(0, 24),
            blurRadius: 48),
      ];
}

/// grasslink motion — gentle, organic. Soft ease-out; spring only on
/// tactile toggles. No bounces on scroll, no flashy entrances.
abstract final class GlMotion {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 360);

  static const easeOut = Cubic(0.22, 0.61, 0.36, 1);
  static const easeInOut = Cubic(0.45, 0, 0.15, 1);
  static const easeSpring = Cubic(0.34, 1.56, 0.64, 1);
}
