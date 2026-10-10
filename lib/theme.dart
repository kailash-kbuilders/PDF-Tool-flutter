import 'package:flutter/material.dart';

class AppColors {
  static const red = Color(0xFFE31B23);
  static const dark = Color(0xFF1E1E1E);
  static const lightBg = Color(0xFFFAFAFA);
  static const darkBg = Color(0xFF121212);
}

class AppTheme {
  static ThemeData light() {
    final s = ColorScheme.fromSeed(
      seedColor: AppColors.red,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.red,
      onPrimary: Colors.white,
      surface: Colors.white,
      onSurface: const Color(0xFF1E1E1E),
      secondaryContainer: const Color(0xFFFFE0E1),
      onSecondaryContainer: const Color(0xFF5C0A0E),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: s,
      scaffoldBackgroundColor: AppColors.lightBg,
    );
  }

  static ThemeData dark() {
    final s = ColorScheme.fromSeed(
      seedColor: AppColors.red,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.red,
      onPrimary: Colors.white,
      surface: AppColors.dark,
      onSurface: Colors.white,
      secondaryContainer: const Color(0xFF5A1519),
      onSecondaryContainer: const Color(0xFFFFDAD9),
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: s,
      scaffoldBackgroundColor: AppColors.darkBg,
    );
  }
}
