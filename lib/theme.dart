import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class KoreTheme {
  // Dark mode color palette (inverted from web aesthetic)
  static const Color _darkBg = Color(0xFF0f0f0f);
  static const Color _darkSurface = Color(0xFF1a1a1a);
  static const Color _darkCard = Color(0xFF242424);
  static const Color _darkBorder = Color(0xFF383838);

  static const Color _textPrimary = Color(0xFFF5F1E8);
  static const Color _textSecondary = Color(0xFFB0A89D);

  static const Color _rust = Color(0xFFcf5f3c);
  static const Color _sage = Color(0xFF8da48b);
  static const Color _rustLight = Color(0xFFe07050);

  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: _darkBg,

      // Color scheme
      colorScheme: ColorScheme.dark(
        background: _darkBg,
        surface: _darkSurface,
        primary: _rust,
        secondary: _sage,
        tertiary: _rustLight,
        onBackground: _textPrimary,
        onSurface: _textPrimary,
        onPrimary: _darkBg,
      ),

      // Typography
      textTheme: _buildTextTheme(),

      // Components
      appBarTheme: AppBarTheme(
        backgroundColor: _darkBg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.spaceGrotesk(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: _textPrimary,
          letterSpacing: 0.5,
        ),
      ),

      cardTheme: CardTheme(
        color: _darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _rust,
          foregroundColor: _darkBg,
          elevation: 0,
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: GoogleFonts.spaceGrotesk(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ).copyWith(
          overlayColor: MaterialStatePropertyAll(_rustLight.withOpacity(0.15)),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _rust,
          side: BorderSide(color: _rust, width: 1),
          padding: EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: GoogleFonts.spaceGrotesk(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _darkCard,
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _darkBorder, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _darkBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _rust, width: 2),
        ),
        hintStyle: GoogleFonts.spaceGrotesk(
          color: _textSecondary,
          fontSize: 14,
        ),
        labelStyle: GoogleFonts.spaceGrotesk(
          color: _textSecondary,
          fontSize: 12,
        ),
      ),

      dividerColor: _darkBorder,
      splashFactory: NoSplash.splashFactory,
    );
  }

  static TextTheme _buildTextTheme() {
    return TextTheme(
      // Display (Fraunces serif for visual hierarchy)
      displayLarge: GoogleFonts.fraunces(
        fontSize: 48,
        fontWeight: FontWeight.w700,
        color: _textPrimary,
        height: 1.05,
      ),
      displayMedium: GoogleFonts.fraunces(
        fontSize: 36,
        fontWeight: FontWeight.w700,
        color: _textPrimary,
        height: 1.1,
      ),
      displaySmall: GoogleFonts.fraunces(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        color: _textPrimary,
      ),

      // Headline (Space Grotesk for UI headers)
      headlineLarge: GoogleFonts.spaceGrotesk(
        fontSize: 24,
        fontWeight: FontWeight.w700,
        color: _textPrimary,
      ),
      headlineMedium: GoogleFonts.spaceGrotesk(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: _textPrimary,
      ),
      headlineSmall: GoogleFonts.spaceGrotesk(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: _textPrimary,
      ),

      // Title (functional headers)
      titleLarge: GoogleFonts.spaceGrotesk(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: _textPrimary,
      ),
      titleMedium: GoogleFonts.spaceGrotesk(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: _textPrimary,
      ),
      titleSmall: GoogleFonts.spaceGrotesk(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: _textPrimary,
      ),

      // Body (readable content)
      bodyLarge: GoogleFonts.spaceGrotesk(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        color: _textPrimary,
        height: 1.6,
      ),
      bodyMedium: GoogleFonts.spaceGrotesk(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        color: _textPrimary,
        height: 1.5,
      ),
      bodySmall: GoogleFonts.spaceGrotesk(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: _textSecondary,
      ),

      // Label (UI accents, tags)
      labelLarge: GoogleFonts.spaceGrotesk(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: _rust,
        letterSpacing: 0.24,
      ),
      labelMedium: GoogleFonts.spaceGrotesk(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: _textSecondary,
        letterSpacing: 0.2,
      ),
      labelSmall: GoogleFonts.spaceGrotesk(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: _textSecondary,
        letterSpacing: 0.15,
      ),
    );
  }

  // Semantic color helpers
  static const Map<String, Color> semanticColors = {
    'success': Color(0xFF4ade80),
    'warning': Color(0xFFfbbf24),
    'error': Color(0xFFef4444),
    'info': Color(0xFF60a5fa),
  };
}
