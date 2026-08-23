import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:groovybox/providers/settings_provider.dart';

part 'theme_provider.g.dart';

// Default seed color
const Color defaultSeedColor = Color.fromRGBO(46, 176, 198, 1);

// State class for theme data
class ThemeState {
  final ThemeMode themeMode;
  final Color seedColor;

  const ThemeState({required this.themeMode, required this.seedColor});

  ThemeState copyWith({ThemeMode? themeMode, Color? seedColor}) {
    return ThemeState(
      themeMode: themeMode ?? this.themeMode,
      seedColor: seedColor ?? this.seedColor,
    );
  }
}

// Light theme definition with dynamic seed color
ThemeData createLightTheme(Color seedColor) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.light,
  ),
  useMaterial3: true,
  inputDecorationTheme: InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
    ),
  ),
);

// Dark theme definition with dynamic seed color
ThemeData createDarkTheme(Color seedColor) => ThemeData(
  colorScheme: ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: Brightness.dark,
  ),
  useMaterial3: true,
  inputDecorationTheme: InputDecorationTheme(
    border: OutlineInputBorder(
      borderRadius: const BorderRadius.all(Radius.circular(12)),
    ),
  ),
);

@Riverpod(keepAlive: true)
class ThemeNotifier extends _$ThemeNotifier {
  @override
  ThemeMode build() {
    // Mirrors the persisted setting so the choice survives restarts.
    return ref.watch(settingsProvider).maybeWhen(
      data: (settings) => settings.themeMode,
      orElse: () => ThemeMode.system,
    );
  }

  Future<void> setThemeMode(ThemeMode themeMode) async {
    await ref.read(settingsProvider.notifier).setThemeMode(themeMode);
  }

  void toggleTheme() {
    switch (state) {
      case ThemeMode.light:
        setThemeMode(ThemeMode.dark);
        break;
      case ThemeMode.dark:
        setThemeMode(ThemeMode.light);
        break;
      case ThemeMode.system:
        // If system, default to light
        setThemeMode(ThemeMode.light);
        break;
    }
  }

  Future<void> setLightTheme() => setThemeMode(ThemeMode.light);
  Future<void> setDarkTheme() => setThemeMode(ThemeMode.dark);
  Future<void> setSystemTheme() => setThemeMode(ThemeMode.system);
}

@Riverpod(keepAlive: true)
class SeedColorNotifier extends _$SeedColorNotifier {
  @override
  Color build() {
    return defaultSeedColor;
  }

  void setSeedColor(Color color) {
    state = color;
  }

  void updateFromAlbumArtBytes(Uint8List? artBytes) async {
    if (artBytes == null || artBytes.isEmpty) {
      // Reset to default color if no album art
      state = defaultSeedColor;
      return;
    }

    try {
      final paletteGenerator = await PaletteGenerator.fromImageProvider(
        MemoryImage(artBytes),
        size: const Size(200, 200),
        maximumColorCount: 20, // Increase color count for better extraction
      );

      // Use dominant color with better fallback hierarchy
      Color? extractedColor;
      if (paletteGenerator.dominantColor != null) {
        extractedColor = paletteGenerator.dominantColor!.color;
      } else if (paletteGenerator.vibrantColor != null) {
        extractedColor = paletteGenerator.vibrantColor!.color;
      } else if (paletteGenerator.mutedColor != null) {
        extractedColor = paletteGenerator.mutedColor!.color;
      } else if (paletteGenerator.paletteColors.isNotEmpty) {
        // Fallback to the first available color
        extractedColor = paletteGenerator.paletteColors.first.color;
      }

      // Ensure we have a valid color, otherwise use default
      state = extractedColor ?? defaultSeedColor;
    } catch (e) {
      // If color extraction fails, reset to default color
      state = defaultSeedColor;
    }
  }

  // Keep the old method for backward compatibility, but mark as deprecated
  @Deprecated(
    'Use updateFromAlbumArtBytes instead. File path based color extraction is unreliable.',
  )
  void updateFromAlbumArt(String? imagePath) async {
    // This method is deprecated, but kept for compatibility
    // It will always reset to default since we now use artBytes
    state = defaultSeedColor;
  }

  void resetToDefault() {
    state = defaultSeedColor;
  }
}

@Riverpod(keepAlive: true)
ThemeData currentTheme(Ref ref) {
  final themeMode = ref.watch(themeProvider);
  final seedColor = ref.watch(seedColorProvider);
  final brightness = themeMode == ThemeMode.system
      ? WidgetsBinding.instance.platformDispatcher.platformBrightness
      : (themeMode == ThemeMode.dark ? Brightness.dark : Brightness.light);

  return brightness == Brightness.dark
      ? createDarkTheme(seedColor)
      : createLightTheme(seedColor);
}

// Legacy providers for backward compatibility
@Riverpod(keepAlive: true)
ThemeData lightTheme(Ref ref) => createLightTheme(ref.watch(seedColorProvider));

@Riverpod(keepAlive: true)
ThemeData darkTheme(Ref ref) => createDarkTheme(ref.watch(seedColorProvider));
