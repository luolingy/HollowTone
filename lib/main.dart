import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:groovybox/logic/audio_handler.dart';
import 'package:groovybox/data/track_repository.dart';
import 'package:groovybox/logic/mpv_hot_restart_cleaner.dart';
import 'package:groovybox/logic/tray_helpers.dart';
import 'package:groovybox/logic/window_helpers.dart';
import 'package:groovybox/providers/audio_provider.dart';
import 'package:groovybox/providers/theme_provider.dart';
import 'package:groovybox/router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:audio_service/audio_service.dart' as audio_service;

late AudioHandler _audioHandler;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Dispose mpv handles left over from a previous hot restart BEFORE
  // media_kit initializes, to avoid "Callback invoked after it has been
  // deleted" crashes in debug mode.
  MpvHotRestartCleaner.clean();
  MediaKit.ensureInitialized();

  // Initialize EasyLocalization
  await EasyLocalization.ensureInitialized();

  // Initialize window manager for desktop platforms
  if (isDesktopPlatform()) {
    await initializeWindowManager();
  }

  // Initialize AudioService
  _audioHandler = await audio_service.AudioService.init(
    builder: () => AudioHandler(),
    config: const audio_service.AudioServiceConfig(
      androidNotificationChannelId: 'io.qzz.luolingy.groovybox.channel.audio',
      androidNotificationChannelName: 'GroovyBox Audio',
      androidNotificationOngoing: true,
    ),
  );

  // Set the audio handler for the provider
  setAudioHandler(_audioHandler);

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('zh')],
      path: 'assets/locales',
      fallbackLocale: const Locale('en'),
      child: ProviderScope(
        child: Builder(
          builder: (context) {
            // Get the provider container and set it on the audio handler
            final container = ProviderScope.containerOf(context);
            _audioHandler.setProviderContainer(container);
            return GroovyApp();
          },
        ),
      ),
    ),
  );
}

class GroovyApp extends ConsumerStatefulWidget {
  const GroovyApp({super.key});

  @override
  ConsumerState<GroovyApp> createState() => _GroovyAppState();
}

class _GroovyAppState extends ConsumerState<GroovyApp> {
  @override
  void initState() {
    super.initState();
    // Keep the app resident in the system tray on desktop platforms.
    Future(() => trayWindowHandler.init());
    // Heal tracks that were imported with broken metadata (e.g. empty titles
    // from flutter_media_metadata's Windows non-ASCII path bug).
    Future(() async {
      try {
        await ref
            .read(trackRepositoryProvider.notifier)
            .repairTracksWithMissingInfo();
      } catch (e) {
        debugPrint('Track metadata repair failed: $e');
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'GroovyBox',
      debugShowCheckedModeBanner: false,
      theme: ref.watch(lightThemeProvider),
      darkTheme: ref.watch(darkThemeProvider),
      themeMode: themeMode,
      routerConfig: router,
      locale: context.locale,
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
    );
  }
}
