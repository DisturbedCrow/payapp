import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  // SetuPay palette — deep indigo + saffron.
  // "setu" = bridge: we bridge the offline gap rather than clone a wallet.
  static const Color navyBlue    = Color(0xFF283593); // deep indigo (primary)
  static const Color paytmBlue   = Color(0xFF5C6BC0); // indigo 400 (secondary)
  static const Color lightBlue   = Color(0xFFF2F3FA); // near-white indigo tint
  static const Color saffron     = Color(0xFFFF9933); // accent
  static const Color yellow      = Color(0xFFFFC107);
  static const Color green       = Color(0xFF4CAF50);
  static const Color orange      = Color(0xFFFF9800);
  static const Color red         = Color(0xFFE53935);

  // Legacy aliases so existing code keeps compiling unchanged.
  // `paytmBlue` is kept as a NAME only — the value is now indigo. Renaming it
  // would touch ~30 call sites for no visual gain.
  static const Color primaryColor   = navyBlue;
  static const Color secondaryColor = paytmBlue;
  static const Color accentColor    = saffron;
  static const Color successColor   = green;
  static const Color warningColor   = orange;
  static const Color errorColor     = red;
  static const Color offlineColor   = Color(0xFFFF7043);
  static const Color surfaceColor   = lightBlue;
  static const Color cardColor      = Colors.white;

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: navyBlue,
        primary: navyBlue,
        secondary: paytmBlue,
        surface: lightBlue,
      ),
      scaffoldBackgroundColor: lightBlue,
      textTheme: GoogleFonts.poppinsTextTheme(),
      appBarTheme: AppBarTheme(
        backgroundColor: lightBlue,
        foregroundColor: navyBlue,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: navyBlue,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: navyBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: navyBlue, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        color: cardColor,
      ),
    );
  }
}
