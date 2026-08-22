import 'dart:ui';

import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'settings_provider.g.dart';

enum ImportMode {
  copy('Copy to internal storage'),
  inplace('In-place indexing'),
  mixed('Mixed (both copy and in-place)');

  const ImportMode(this.displayName);
  final String displayName;
}

enum DefaultPlayerScreen {
  cover('Cover'),
  lyrics('Lyrics'),
  queue('Queue');

  const DefaultPlayerScreen(this.displayName);
  final String displayName;
}

enum LyricsMode {
  curved('Fan'),
  flat('Flat'),
  auto('Auto');

  const LyricsMode(this.displayName);
  final String displayName;
}

class SettingsState {
  final ImportMode importMode;
  final bool autoScan;
  final bool watchForChanges;
  final DefaultPlayerScreen defaultPlayerScreen;
  final LyricsMode lyricsMode;
  final bool continuePlays;
  final Set<String> supportedFormats;
  final Size? windowSize;

  const SettingsState({
    this.importMode = ImportMode.mixed,
    this.autoScan = true,
    this.watchForChanges = true,
    this.defaultPlayerScreen = DefaultPlayerScreen.cover,
    this.lyricsMode = LyricsMode.auto,
    this.continuePlays = false,
    this.supportedFormats = const {
      '.mp3',
      '.flac',
      '.wav',
      '.m4a',
      '.aac',
      '.ogg',
      '.wma',
      '.opus',
    },
    this.windowSize,
  });

  SettingsState copyWith({
    ImportMode? importMode,
    bool? autoScan,
    bool? watchForChanges,
    DefaultPlayerScreen? defaultPlayerScreen,
    LyricsMode? lyricsMode,
    bool? continuePlays,
    Set<String>? supportedFormats,
    Size? windowSize,
  }) {
    return SettingsState(
      importMode: importMode ?? this.importMode,
      autoScan: autoScan ?? this.autoScan,
      watchForChanges: watchForChanges ?? this.watchForChanges,
      defaultPlayerScreen: defaultPlayerScreen ?? this.defaultPlayerScreen,
      lyricsMode: lyricsMode ?? this.lyricsMode,
      continuePlays: continuePlays ?? this.continuePlays,
      supportedFormats: supportedFormats ?? this.supportedFormats,
      windowSize: windowSize ?? this.windowSize,
    );
  }
}

@riverpod
class SettingsNotifier extends _$SettingsNotifier {
  static const String _importModeKey = 'import_mode';
  static const String _autoScanKey = 'auto_scan';
  static const String _watchForChangesKey = 'watch_for_changes';
  static const String _defaultPlayerScreenKey = 'default_player_screen';
  static const String _lyricsModeKey = 'lyrics_mode';
  static const String _continuePlaysKey = 'continue_plays';
  static const String _windowWidthKey = 'window_width';
  static const String _windowHeightKey = 'window_height';

  @override
  Future<SettingsState> build() async {
    final prefs = await SharedPreferences.getInstance();

    final importModeIndex = prefs.getInt(_importModeKey) ?? 0;
    final importMode = ImportMode.values[importModeIndex];

    final autoScan = prefs.getBool(_autoScanKey) ?? true;
    final watchForChanges = prefs.getBool(_watchForChangesKey) ?? true;

    final defaultPlayerScreenIndex = prefs.getInt(_defaultPlayerScreenKey) ?? 0;
    final defaultPlayerScreen =
        DefaultPlayerScreen.values[defaultPlayerScreenIndex];

    final lyricsModeIndex =
        prefs.getInt(_lyricsModeKey) ?? 2; // Auto is default
    final lyricsMode = LyricsMode.values[lyricsModeIndex];

    final continuePlays = prefs.getBool(_continuePlaysKey) ?? false;

    // Load window size
    Size? windowSize;
    final windowWidth = prefs.getDouble(_windowWidthKey);
    final windowHeight = prefs.getDouble(_windowHeightKey);
    if (windowWidth != null && windowHeight != null) {
      windowSize = Size(windowWidth, windowHeight);
    }

    return SettingsState(
      importMode: importMode,
      autoScan: autoScan,
      watchForChanges: watchForChanges,
      defaultPlayerScreen: defaultPlayerScreen,
      lyricsMode: lyricsMode,
      continuePlays: continuePlays,
      windowSize: windowSize,
    );
  }

  Future<void> setImportMode(ImportMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_importModeKey, mode.index);

    if (state.hasValue) {
      state = AsyncValue.data(state.value!.copyWith(importMode: mode));
    }
  }

  Future<void> setAutoScan(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoScanKey, enabled);

    if (state.hasValue) {
      state = AsyncValue.data(state.value!.copyWith(autoScan: enabled));
    }
  }

  Future<void> setWatchForChanges(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_watchForChangesKey, enabled);

    if (state.hasValue) {
      state = AsyncValue.data(state.value!.copyWith(watchForChanges: enabled));
    }
  }

  Future<void> setDefaultPlayerScreen(DefaultPlayerScreen screen) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_defaultPlayerScreenKey, screen.index);

    if (state.hasValue) {
      state = AsyncValue.data(
        state.value!.copyWith(defaultPlayerScreen: screen),
      );
    }
  }

  Future<void> setLyricsMode(LyricsMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lyricsModeKey, mode.index);

    if (state.hasValue) {
      state = AsyncValue.data(state.value!.copyWith(lyricsMode: mode));
    }
  }

  Future<void> setContinuePlays(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_continuePlaysKey, enabled);

    if (state.hasValue) {
      state = AsyncValue.data(state.value!.copyWith(continuePlays: enabled));
    }
  }

  Future<void> setWindowSize(Size size) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_windowWidthKey, size.width);
    await prefs.setDouble(_windowHeightKey, size.height);

    if (state.hasValue) {
      state = AsyncValue.data(state.value!.copyWith(windowSize: size));
    }
  }
}

// Convenience providers for specific settings
@riverpod
class ImportModeNotifier extends _$ImportModeNotifier {
  @override
  ImportMode build() {
    return ref
        .watch(settingsProvider)
        .when(
          data: (settings) => settings.importMode,
          loading: () => ImportMode.mixed,
          error: (_, _) => ImportMode.mixed,
        );
  }

  Future<void> update(ImportMode mode) async {
    await ref.read(settingsProvider.notifier).setImportMode(mode);
  }
}

@riverpod
class AutoScanNotifier extends _$AutoScanNotifier {
  @override
  bool build() {
    return ref
        .watch(settingsProvider)
        .when(
          data: (settings) => settings.autoScan,
          loading: () => true,
          error: (_, _) => true,
        );
  }

  Future<void> update(bool enabled) async {
    await ref.read(settingsProvider.notifier).setAutoScan(enabled);
  }
}

@riverpod
class WatchForChangesNotifier extends _$WatchForChangesNotifier {
  @override
  bool build() {
    return ref
        .watch(settingsProvider)
        .when(
          data: (settings) => settings.watchForChanges,
          loading: () => true,
          error: (_, _) => true,
        );
  }

  Future<void> update(bool enabled) async {
    await ref.read(settingsProvider.notifier).setWatchForChanges(enabled);
  }
}

@riverpod
class DefaultPlayerScreenNotifier extends _$DefaultPlayerScreenNotifier {
  @override
  DefaultPlayerScreen build() {
    return ref
        .watch(settingsProvider)
        .when(
          data: (settings) => settings.defaultPlayerScreen,
          loading: () => DefaultPlayerScreen.cover,
          error: (_, _) => DefaultPlayerScreen.cover,
        );
  }

  Future<void> update(DefaultPlayerScreen screen) async {
    await ref.read(settingsProvider.notifier).setDefaultPlayerScreen(screen);
  }
}

@riverpod
class LyricsModeNotifier extends _$LyricsModeNotifier {
  @override
  LyricsMode build() {
    return ref
        .watch(settingsProvider)
        .when(
          data: (settings) => settings.lyricsMode,
          loading: () => LyricsMode.auto,
          error: (_, _) => LyricsMode.auto,
        );
  }

  Future<void> update(LyricsMode mode) async {
    await ref.read(settingsProvider.notifier).setLyricsMode(mode);
  }
}

@riverpod
class ContinuePlaysNotifier extends _$ContinuePlaysNotifier {
  @override
  bool build() {
    return ref
        .watch(settingsProvider)
        .when(
          data: (settings) => settings.continuePlays,
          loading: () => false,
          error: (_, _) => false,
        );
  }

  Future<void> update(bool enabled) async {
    await ref.read(settingsProvider.notifier).setContinuePlays(enabled);
  }
}
