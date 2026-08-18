import 'package:flutter/material.dart';

/// KORE's dark visual identity.
///
/// Fonts are bundled as assets (see pubspec.yaml) rather than fetched at
/// runtime, so the app renders identically with no network available.
class KoreTheme {
  // ---------------------------------------------------------------------
  // Palette. Public because the CustomPainters (gauge, sparkline) need the
  // raw colors directly - they paint to a Canvas and have no BuildContext
  // worth threading a Theme.of() through.
  // ---------------------------------------------------------------------
  static const Color bg = Color(0xFF0f0f0f);
  static const Color surface = Color(0xFF1a1a1a);
  static const Color card = Color(0xFF242424);
  static const Color border = Color(0xFF383838);

  static const Color textPrimary = Color(0xFFF5F1E8);
  static const Color textSecondary = Color(0xFFB0A89D);

  /// Strain / high cognitive load.
  static const Color rust = Color(0xFFcf5f3c);

  /// Calm / recovered.
  static const Color sage = Color(0xFF8da48b);
  static const Color rustLight = Color(0xFFe07050);

  static const String _sans = 'SpaceGrotesk';
  static const String _serif = 'Fraunces';

  static TextStyle _grotesk({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: _sans,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );

  static TextStyle _fraunces({
    double? fontSize,
    FontWeight? fontWeight,
    Color? color,
    double? height,
  }) =>
      TextStyle(
        fontFamily: _serif,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
      );

  /// Monospaced-ish numerals for the big readout. Space Grotesk has tabular
  /// figures, so digits do not jitter as the index ticks.
  static TextStyle numerals({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w700,
    Color color = textPrimary,
  }) =>
      TextStyle(
        fontFamily: _sans,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        fontFeatures: const [FontFeature.tabularFigures()],
        height: 1.0,
      );

  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,

      colorScheme: const ColorScheme.dark(
        surface: surface,
        primary: rust,
        secondary: sage,
        tertiary: rustLight,
        onSurface: textPrimary,
        onPrimary: bg,
      ),

      textTheme: _buildTextTheme(),

      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: _grotesk(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: 0.5,
        ),
      ),

      // ThemeData.cardTheme is typed CardThemeData in Flutter 3.44+;
      // CardTheme itself is now an InheritedWidget.
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: rust,
          foregroundColor: bg,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: _grotesk(fontSize: 15, fontWeight: FontWeight.w600),
        ).copyWith(
          overlayColor:
              WidgetStatePropertyAll(rustLight.withValues(alpha: 0.15)),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: rust,
          side: const BorderSide(color: rust, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: _grotesk(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: card,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: border, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: border, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: rust, width: 2),
        ),
        hintStyle: _grotesk(color: textSecondary, fontSize: 14),
        labelStyle: _grotesk(color: textSecondary, fontSize: 12),
      ),

      dividerColor: border,
      splashFactory: NoSplash.splashFactory,
    );
  }

  static TextTheme _buildTextTheme() {
    return TextTheme(
      // Display - Fraunces serif, for visual hierarchy
      displayLarge: _fraunces(
          fontSize: 48,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          height: 1.05),
      displayMedium: _fraunces(
          fontSize: 36,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          height: 1.1),
      displaySmall: _fraunces(
          fontSize: 28, fontWeight: FontWeight.w600, color: textPrimary),

      // Headline - Space Grotesk, for UI headers
      headlineLarge: _grotesk(
          fontSize: 24, fontWeight: FontWeight.w700, color: textPrimary),
      headlineMedium: _grotesk(
          fontSize: 20, fontWeight: FontWeight.w700, color: textPrimary),
      headlineSmall: _grotesk(
          fontSize: 16, fontWeight: FontWeight.w600, color: textPrimary),

      // Title - functional headers
      titleLarge: _grotesk(
          fontSize: 18, fontWeight: FontWeight.w600, color: textPrimary),
      titleMedium: _grotesk(
          fontSize: 16, fontWeight: FontWeight.w600, color: textPrimary),
      titleSmall: _grotesk(
          fontSize: 14, fontWeight: FontWeight.w600, color: textPrimary),

      // Body - readable content
      bodyLarge: _grotesk(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: textPrimary,
          height: 1.6),
      bodyMedium: _grotesk(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: textPrimary,
          height: 1.5),
      bodySmall: _grotesk(
          fontSize: 12, fontWeight: FontWeight.w400, color: textSecondary),

      // Label - UI accents, tags
      labelLarge: _grotesk(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: rust,
          letterSpacing: 0.24),
      labelMedium: _grotesk(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: textSecondary,
          letterSpacing: 0.2),
      labelSmall: _grotesk(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          color: textSecondary,
          letterSpacing: 0.15),
    );
  }

  static const Map<String, Color> semanticColors = {
    'success': Color(0xFF4ade80),
    'warning': Color(0xFFfbbf24),
    'error': Color(0xFFef4444),
    'info': Color(0xFF60a5fa),
  };
}
