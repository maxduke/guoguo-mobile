import 'package:flutter/material.dart';

const forest = Color(0xFF235849);
const cream = Color(0xFFF7F5EF);
const amber = Color(0xFFBD8A44);

ThemeData guoguoTheme(Brightness brightness, {bool television = false}) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: forest, brightness: brightness)
      .copyWith(
        primary: dark ? const Color(0xFF9DCDB0) : forest,
        surface: dark ? const Color(0xFF171D1A) : cream,
        secondary: dark ? const Color(0xFFDFC18C) : amber,
        surfaceContainerLow: dark
            ? const Color(0xFF202823)
            : const Color(0xFFFFFFFF),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'sans-serif',
    focusColor: scheme.primary.withValues(alpha: television ? .28 : .12),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: television ? 72 : null,
    ),
    textTheme: TextTheme(
      headlineLarge: const TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w700,
        letterSpacing: -1,
      ),
      headlineMedium: const TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: -.6,
      ),
      titleLarge: const TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
      titleMedium: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      bodyMedium: const TextStyle(fontSize: 14, height: 1.5),
      bodySmall: television ? const TextStyle(fontSize: 14) : null,
      labelLarge: television
          ? const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)
          : null,
    ).apply(fontSizeFactor: television ? 1.15 : 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surface,
      indicatorColor: scheme.primary.withValues(alpha: .13),
      height: 74,
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            minimumSize: Size(television ? 56 : 48, television ? 56 : 48),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ).copyWith(
            side: WidgetStateProperty.resolveWith(
              (states) => television && states.contains(WidgetState.focused)
                  ? BorderSide(color: scheme.onSurface, width: 3)
                  : BorderSide.none,
            ),
          ),
    ),
    iconButtonTheme: television
        ? IconButtonThemeData(
            style: ButtonStyle(
              minimumSize: WidgetStatePropertyAll(
                Size(television ? 56 : 48, television ? 56 : 48),
              ),
              side: WidgetStateProperty.resolveWith(
                (states) => television && states.contains(WidgetState.focused)
                    ? BorderSide(color: scheme.primary, width: 3)
                    : BorderSide.none,
              ),
            ),
          )
        : const IconButtonThemeData(),
    textButtonTheme: television
        ? TextButtonThemeData(
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(56, 56)),
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? BorderSide(color: scheme.primary, width: 3)
                    : BorderSide.none,
              ),
            ),
          )
        : const TextButtonThemeData(),
    outlinedButtonTheme: television
        ? OutlinedButtonThemeData(
            style: ButtonStyle(
              minimumSize: const WidgetStatePropertyAll(Size(56, 56)),
              side: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.focused)
                    ? BorderSide(color: scheme.primary, width: 3)
                    : BorderSide(color: scheme.outline),
              ),
            ),
          )
        : const OutlinedButtonThemeData(),
    chipTheme: ChipThemeData(
      side: television
          ? WidgetStateBorderSide.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? BorderSide(color: scheme.primary, width: 3)
                  : BorderSide.none,
            )
          : BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant.withValues(alpha: .5),
    ),
  );
}
