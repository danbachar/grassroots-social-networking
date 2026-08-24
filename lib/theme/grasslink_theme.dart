import 'package:flutter/material.dart';

import 'grasslink_tokens.dart';

/// The grasslink Material theme — light only, per the design system (warm
/// cream pages, dark clay text; no dark variant is defined by the brand).
///
/// Widgets pick up almost everything from here; screens reference
/// [GlColors]/[GlSpace]/[GlRadius]/[GlShadows]/[GlMotion] directly for the
/// rest. No hardcoded hex values outside `grasslink_tokens.dart`.
ThemeData grasslinkTheme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: GlColors.primary,
    onPrimary: GlColors.textOnPrimary,
    primaryContainer: GlColors.primarySoft,
    onPrimaryContainer: GlColors.primaryOnSoft,
    secondary: GlColors.accent,
    onSecondary: GlColors.textOnPrimary,
    secondaryContainer: GlColors.accentSoft,
    onSecondaryContainer: GlColors.accentOnSoft,
    tertiary: GlColors.info,
    onTertiary: GlColors.textOnPrimary,
    tertiaryContainer: GlColors.infoSoft,
    onTertiaryContainer: GlColors.sky500,
    error: GlColors.danger,
    onError: GlColors.textOnPrimary,
    errorContainer: GlColors.dangerSoft,
    onErrorContainer: GlColors.rust500,
    surface: GlColors.surfaceCard,
    onSurface: GlColors.textBody,
    onSurfaceVariant: GlColors.textMuted,
    surfaceContainerLowest: GlColors.surfaceCard,
    surfaceContainerLow: GlColors.bgPage,
    surfaceContainer: GlColors.bgSunken,
    surfaceContainerHigh: GlColors.bgSunken,
    surfaceContainerHighest: GlColors.clay200,
    outline: GlColors.borderDefault,
    outlineVariant: GlColors.borderSubtle,
    shadow: GlColors.shadowTint,
    scrim: GlColors.scrim,
    inverseSurface: GlColors.surfaceInverse,
    onInverseSurface: GlColors.textInverse,
    inversePrimary: GlColors.moss200,
    surfaceTint: Colors.transparent,
  );

  TextStyle sans(double size, FontWeight weight,
          {Color color = GlColors.textBody, double? tracking}) =>
      TextStyle(
        fontFamily: GlType.sans,
        fontSize: size,
        fontWeight: weight,
        color: color,
        letterSpacing: (tracking ?? 0) * size,
        height: 1.5,
      );

  final textTheme = TextTheme(
    // Display & headlines — Bricolage Grotesque, extrabold, tight.
    displayLarge: GlType.displayStyle(GlType.text4xl),
    displayMedium: GlType.displayStyle(GlType.text3xl),
    displaySmall: GlType.displayStyle(GlType.text2xl),
    headlineLarge: GlType.displayStyle(GlType.text2xl),
    headlineMedium: GlType.displayStyle(GlType.textXl, weight: FontWeight.w700),
    headlineSmall:
        GlType.displayStyle(GlType.textLg, weight: FontWeight.w700),
    // Titles & UI text — Hanken Grotesk.
    titleLarge: sans(GlType.textLg, FontWeight.w600,
        color: GlColors.textStrong, tracking: GlType.trackingSnug),
    titleMedium: sans(GlType.textMd, FontWeight.w600,
        color: GlColors.textStrong, tracking: GlType.trackingSnug),
    titleSmall: sans(GlType.textSm, FontWeight.w600, color: GlColors.textStrong),
    bodyLarge: sans(GlType.textMd, FontWeight.w400),
    bodyMedium: sans(GlType.textSm, FontWeight.w400),
    bodySmall: sans(GlType.textXs, FontWeight.w400, color: GlColors.textMuted),
    labelLarge: sans(GlType.textMd, FontWeight.w600),
    labelMedium: sans(GlType.textSm, FontWeight.w500),
    labelSmall: sans(GlType.text2xs, FontWeight.w600,
        color: GlColors.textMuted, tracking: GlType.trackingWide),
  );

  final baseBorder = OutlineInputBorder(
    borderRadius: GlRadius.rMd,
    borderSide: const BorderSide(color: GlColors.borderDefault, width: 1.5),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: GlColors.bgPage,
    canvasColor: GlColors.bgPage,
    fontFamily: GlType.sans,
    textTheme: textTheme,
    splashFactory: InkRipple.splashFactory,
    splashColor: GlColors.clay100,
    highlightColor: GlColors.clay100.withValues(alpha: 0.6),
    hoverColor: GlColors.clay100,
    dividerColor: GlColors.borderSubtle,

    appBarTheme: AppBarTheme(
      backgroundColor: GlColors.bgPage,
      foregroundColor: GlColors.textStrong,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: GlType.displayStyle(GlType.textXl),
      iconTheme: const IconThemeData(color: GlColors.textBody, size: 22),
    ),

    cardTheme: CardThemeData(
      color: GlColors.surfaceCard,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: GlRadius.rLg,
        side: const BorderSide(color: GlColors.borderSubtle),
      ),
      margin: const EdgeInsets.symmetric(
          horizontal: GlSpace.s4, vertical: GlSpace.s2),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: GlColors.primary,
        foregroundColor: GlColors.textOnPrimary,
        textStyle: sans(GlType.textMd, FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: GlRadius.rMd),
        padding: const EdgeInsets.symmetric(
            horizontal: GlSpace.s5, vertical: GlSpace.s3),
      ).copyWith(
        overlayColor: const WidgetStatePropertyAll(GlColors.primaryActive),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: GlColors.primary,
        foregroundColor: GlColors.textOnPrimary,
        disabledBackgroundColor: GlColors.clay200,
        disabledForegroundColor: GlColors.textSubtle,
        elevation: 0,
        textStyle: sans(GlType.textMd, FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: GlRadius.rMd),
        padding: const EdgeInsets.symmetric(
            horizontal: GlSpace.s5, vertical: GlSpace.s3),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: GlColors.textBody,
        side: const BorderSide(color: GlColors.borderDefault, width: 1.5),
        textStyle: sans(GlType.textMd, FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: GlRadius.rMd),
        padding: const EdgeInsets.symmetric(
            horizontal: GlSpace.s5, vertical: GlSpace.s3),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: GlColors.primaryHover,
        textStyle: sans(GlType.textMd, FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: GlRadius.rSm),
      ),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: GlColors.surfaceCard,
      hintStyle: sans(GlType.textMd, FontWeight.w400, color: GlColors.textSubtle),
      labelStyle: sans(GlType.textSm, FontWeight.w500, color: GlColors.textMuted),
      contentPadding: const EdgeInsets.symmetric(
          horizontal: GlSpace.s4, vertical: GlSpace.s3),
      border: baseBorder,
      enabledBorder: baseBorder,
      focusedBorder: baseBorder.copyWith(
        borderSide: const BorderSide(color: GlColors.primary, width: 1.5),
      ),
      errorBorder: baseBorder.copyWith(
        borderSide: const BorderSide(color: GlColors.danger, width: 1.5),
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected)
              ? GlColors.primary
              : GlColors.clay300),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),

    chipTheme: ChipThemeData(
      backgroundColor: GlColors.bgSunken,
      selectedColor: GlColors.primarySoft,
      labelStyle: sans(GlType.textSm, FontWeight.w500, color: GlColors.clay700),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: GlRadius.rPill),
      padding: const EdgeInsets.symmetric(
          horizontal: GlSpace.s3, vertical: GlSpace.s1),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: GlColors.surfaceCard,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: GlRadius.rXl),
      titleTextStyle: GlType.displayStyle(GlType.textXl,
          weight: FontWeight.w700, color: GlColors.textStrong),
      contentTextStyle: sans(GlType.textMd, FontWeight.w400),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: GlColors.surfaceCard,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(GlRadius.xl)),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: GlColors.surfaceInverse,
      contentTextStyle:
          sans(GlType.textSm, FontWeight.w500, color: GlColors.textInverse),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: GlRadius.rMd),
    ),

    tabBarTheme: TabBarThemeData(
      labelColor: GlColors.primaryOnSoft,
      unselectedLabelColor: GlColors.textMuted,
      labelStyle: sans(GlType.textSm, FontWeight.w600),
      unselectedLabelStyle: sans(GlType.textSm, FontWeight.w500),
      indicatorSize: TabBarIndicatorSize.tab,
      dividerColor: Colors.transparent,
      indicator: BoxDecoration(
        color: GlColors.primarySoft,
        borderRadius: GlRadius.rPill,
      ),
    ),

    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: GlColors.surfaceCard,
      indicatorColor: GlColors.primarySoft,
      surfaceTintColor: Colors.transparent,
      labelTextStyle: WidgetStateProperty.resolveWith((states) => sans(
          GlType.text2xs,
          states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
          color: states.contains(WidgetState.selected)
              ? GlColors.primaryOnSoft
              : GlColors.textSubtle)),
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? GlColors.primaryOnSoft
              : GlColors.textSubtle)),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: GlColors.primary,
      foregroundColor: GlColors.textOnPrimary,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: GlRadius.rLg),
    ),

    listTileTheme: ListTileThemeData(
      iconColor: GlColors.textMuted,
      textColor: GlColors.textBody,
      titleTextStyle:
          sans(GlType.textMd, FontWeight.w600, color: GlColors.textStrong),
      subtitleTextStyle:
          sans(GlType.textSm, FontWeight.w400, color: GlColors.textMuted),
      shape: RoundedRectangleBorder(borderRadius: GlRadius.rLg),
    ),

    dividerTheme: const DividerThemeData(
      color: GlColors.borderSubtle,
      thickness: 1,
      space: 1,
    ),

    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: GlColors.primary,
      linearTrackColor: GlColors.clay200,
      circularTrackColor: GlColors.clay200,
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: GlColors.surfaceCard,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: GlRadius.rMd),
      textStyle: sans(GlType.textSm, FontWeight.w500),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: GlColors.surfaceInverse,
        borderRadius: GlRadius.rSm,
      ),
      textStyle:
          sans(GlType.textXs, FontWeight.w500, color: GlColors.textInverse),
    ),
  );
}
