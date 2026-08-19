import 'package:flutter/material.dart';

import 'colors.dart';
import 'components.dart';
import 'metrics.dart';

export 'colors.dart';
export 'components.dart';
export 'load_ramp.dart';
export 'metrics.dart';
export 'primitives.dart';

/// Assembles the token layers into a Flutter [ThemeData].
///
/// Fonts are bundled as assets (see pubspec.yaml) rather than fetched at
/// runtime, so the app renders identically with no network available.
class KoreTheme {
  KoreTheme._();

  static ThemeData dark() => _build(Brightness.dark, KoreColors.dark);

  static ThemeData light() => _build(Brightness.light, KoreColors.light);

  static ThemeData _build(Brightness brightness, KoreColors k) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: k.canvas,
      extensions: [k],

      colorScheme: ColorScheme(
        brightness: brightness,
        surface: k.surface,
        onSurface: k.textPrimary,
        primary: k.accent,
        onPrimary: k.onAccent,
        secondary: k.calm,
        onSecondary: k.onAccent,
        // KORE has no destructive actions. Pointing `error` at the strain
        // colour keeps a stray Material error state inside the palette
        // instead of introducing a signal red the product never uses.
        error: k.strain,
        onError: k.onAccent,
      ),

      textTheme: _textTheme(k),

      appBarTheme: AppBarTheme(
        backgroundColor: k.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: KoreType.sansStyle(
          fontSize: KoreType.size20,
          fontWeight: FontWeight.w700,
          color: k.textPrimary,
          letterSpacing: 0.5,
        ),
      ),

      // ThemeData.cardTheme is typed CardThemeData in Flutter 3.44+;
      // CardTheme itself is now an InheritedWidget.
      cardTheme: CardThemeData(
        color: k.card,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(KoreRadius.lg),
          side: BorderSide(color: k.border),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: k.accent,
          foregroundColor: k.onAccent,
          elevation: 0,
          // A primary action is a full-height target on every surface. On a
          // phone this is the one control a tired thumb has to find.
          minimumSize: const Size(0, kMinTouchTarget),
          padding: const EdgeInsets.symmetric(
              horizontal: KoreSpace.xl, vertical: KoreSpace.sm),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(KoreRadius.pill)),
          textStyle: KoreType.sansStyle(
              fontSize: KoreType.size16, fontWeight: FontWeight.w600),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: k.accent,
          side: BorderSide(color: k.accent, width: 1),
          minimumSize: const Size(0, kMinTouchTarget),
          padding: const EdgeInsets.symmetric(
              horizontal: KoreSpace.lg, vertical: KoreSpace.sm),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(KoreRadius.pill)),
          textStyle: KoreType.sansStyle(
              fontSize: KoreType.size14, fontWeight: FontWeight.w600),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: k.textSecondary,
          minimumSize: const Size(0, kMinTouchTarget),
          textStyle: KoreType.sansStyle(fontSize: KoreType.size14),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: k.surface,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: k.borderStrong,
        shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(KoreRadius.lg)),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: k.card,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: KoreSpace.md, vertical: KoreSpace.sm),
        border: _inputBorder(k.border, 1),
        enabledBorder: _inputBorder(k.border, 1),
        focusedBorder: _inputBorder(k.accent, 2),
        hintStyle:
            KoreType.sansStyle(color: k.textSecondary, fontSize: KoreType.size14),
        labelStyle:
            KoreType.sansStyle(color: k.textSecondary, fontSize: KoreType.size12),
      ),

      dividerColor: k.border,
      // Ripples are noise on a surface whose whole job is to be quiet.
      splashFactory: NoSplash.splashFactory,
    );
  }

  static OutlineInputBorder _inputBorder(Color color, double width) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(KoreRadius.md),
        borderSide: BorderSide(color: color, width: width),
      );

  static TextTheme _textTheme(KoreColors k) {
    return TextTheme(
      // Display - Fraunces serif, for visual hierarchy
      displayLarge: KoreType.serifStyle(
          fontSize: KoreType.size48,
          fontWeight: FontWeight.w700,
          color: k.textPrimary,
          height: 1.05),
      displayMedium: KoreType.serifStyle(
          fontSize: KoreType.size36,
          fontWeight: FontWeight.w700,
          color: k.textPrimary,
          height: 1.1),
      displaySmall: KoreType.serifStyle(
          fontSize: KoreType.size28,
          fontWeight: FontWeight.w600,
          color: k.textPrimary),

      // Headline - Space Grotesk, for UI headers
      headlineLarge: KoreType.sansStyle(
          fontSize: KoreType.size24,
          fontWeight: FontWeight.w700,
          color: k.textPrimary),
      headlineMedium: KoreType.sansStyle(
          fontSize: KoreType.size20,
          fontWeight: FontWeight.w700,
          color: k.textPrimary),
      headlineSmall: KoreType.sansStyle(
          fontSize: KoreType.size16,
          fontWeight: FontWeight.w600,
          color: k.textPrimary),

      // Title - functional headers
      titleLarge: KoreType.sansStyle(
          fontSize: KoreType.size18,
          fontWeight: FontWeight.w600,
          color: k.textPrimary),
      titleMedium: KoreType.sansStyle(
          fontSize: KoreType.size16,
          fontWeight: FontWeight.w600,
          color: k.textPrimary),
      titleSmall: KoreType.sansStyle(
          fontSize: KoreType.size14,
          fontWeight: FontWeight.w600,
          color: k.textPrimary),

      // Body - readable content
      bodyLarge: KoreType.sansStyle(
          fontSize: KoreType.size16,
          fontWeight: FontWeight.w400,
          color: k.textPrimary,
          height: 1.6),
      bodyMedium: KoreType.sansStyle(
          fontSize: KoreType.size14,
          fontWeight: FontWeight.w400,
          color: k.textPrimary,
          height: 1.5),
      bodySmall: KoreType.sansStyle(
          fontSize: KoreType.size12,
          fontWeight: FontWeight.w400,
          color: k.textSecondary),

      // Label - panel headers and tags
      labelLarge: KoreType.sansStyle(
          fontSize: KoreType.size12,
          fontWeight: FontWeight.w600,
          color: k.accent,
          letterSpacing: 0.24),
      labelMedium: KoreType.sansStyle(
          fontSize: KoreType.size11,
          fontWeight: FontWeight.w600,
          color: k.textSecondary,
          letterSpacing: 0.2),
      labelSmall: KoreType.sansStyle(
          fontSize: KoreType.size10,
          fontWeight: FontWeight.w500,
          color: k.textSecondary,
          letterSpacing: 0.15),
    );
  }
}

extension KoreThemeAccess on BuildContext {
  /// The resolved colour roles. Falls back to the dark set so a widget
  /// pumped bare in a test still paints something coherent rather than
  /// throwing on a missing extension.
  KoreColors get kore =>
      Theme.of(this).extension<KoreColors>() ?? KoreColors.dark;

  KoreWindow get koreWindow =>
      KoreBreakpoints.classify(MediaQuery.sizeOf(this));
}
