import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:go_router/go_router.dart';
import 'package:groovybox/data/track_repository.dart';
import 'package:groovybox/logic/lyrics_parser.dart';
import 'package:groovybox/logic/window_helpers.dart';
import 'package:groovybox/providers/settings_provider.dart';
import 'package:groovybox/router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:styled_widget/styled_widget.dart';
import 'package:window_manager/window_manager.dart';
import 'screens/library_screen.dart';
import 'widgets/mini_player.dart';

// Navigation intents and actions
class PopIntent extends Intent {
  const PopIntent();
}

class PopAction extends Action<PopIntent> {
  final WidgetRef ref;

  PopAction(this.ref);

  @override
  void invoke(PopIntent intent) {
    // Handle pop navigation
    // Since we don't have a router, we can handle back navigation here if needed
  }
}

// Window management helpers
class _WindowSizeObserver extends WidgetsBindingObserver {
  final VoidCallback callback;

  _WindowSizeObserver(this.callback);

  @override
  void didChangeMetrics() {
    callback();
  }
}

class _WindowMaximizeListener extends WindowListener {
  final ValueNotifier<bool> isMaximized;

  _WindowMaximizeListener(this.isMaximized);

  @override
  void onWindowMaximize() {
    isMaximized.value = true;
  }

  @override
  void onWindowUnmaximize() {
    isMaximized.value = false;
  }

  @override
  void onWindowRestore() {
    isMaximized.value = false;
  }
}

class Shell extends HookConsumerWidget {
  final Widget child;

  const Shell({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMaximized = useState(false);

    // Add window resize listener for desktop platforms
    useEffect(() {
      if (isDesktopPlatform()) {
        void saveWindowSize() {
          windowManager.getBounds().then((bounds) {
            final settingsNotifier = ref.read(settingsProvider.notifier);
            Future(() {
              settingsNotifier.setWindowSize(bounds.size);
            });
          });
        }

        // Save window size when app is about to close
        WidgetsBinding.instance.addObserver(
          _WindowSizeObserver(saveWindowSize),
        );

        final maximizeListener = _WindowMaximizeListener(isMaximized);
        windowManager.addListener(maximizeListener);
        windowManager.isMaximized().then((max) => isMaximized.value = max);

        return () {
          // Cleanup observer when widget is disposed
          WidgetsBinding.instance.removeObserver(
            _WindowSizeObserver(saveWindowSize),
          );
          windowManager.removeListener(maximizeListener);
        };
      }
      return null;
    }, []);

    final pageActionsButton = [
      IconButton(
        onPressed: () => context.push(AppRoutes.settings),
        icon: const Icon(Symbols.settings),
        padding: EdgeInsets.all(8),
        constraints: BoxConstraints(),
        color: Theme.of(context).iconTheme.color,
        iconSize: 16,
      ),
      IconButton(
        icon: const Icon(Symbols.add_circle_outline),
        iconSize: 16,
        padding: EdgeInsets.all(8),
        constraints: BoxConstraints(),
        color: Theme.of(context).iconTheme.color,
        tooltip: 'Import Files',
        onPressed: () async {
          final result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: LibraryScreen.allAllowedExtensions,
            allowMultiple: true,
          );
          if (result != null && result.files.isNotEmpty) {
            final paths = result.files
                .map((f) => f.path)
                .whereType<String>()
                .toList();
            if (paths.isNotEmpty) {
              // Separate audio and lyrics files
              final audioPaths = paths.where((path) {
                final ext = p
                    .extension(path)
                    .toLowerCase()
                    .replaceFirst('.', '');
                return LibraryScreen.audioExtensions.contains(ext);
              }).toList();
              final lyricsPaths = paths.where((path) {
                final ext = p
                    .extension(path)
                    .toLowerCase()
                    .replaceFirst('.', '');
                return LibraryScreen.lyricsExtensions.contains(ext);
              }).toList();

              // Import tracks if any
              if (audioPaths.isNotEmpty) {
                final repo = ref.watch(trackRepositoryProvider.notifier);
                await repo.importFiles(audioPaths);
              }

              // Import lyrics if any
              if (!context.mounted) return;
              if (lyricsPaths.isNotEmpty) {
                await _batchImportLyricsFromPaths(context, ref, lyricsPaths);
              }
            }
          }
        },
      ),
      IconButton(
        icon: Icon(Symbols.home),
        onPressed: () => context.go(AppRoutes.library),
        iconSize: 16,
        padding: EdgeInsets.all(8),
        constraints: BoxConstraints(),
        color: Theme.of(context).iconTheme.color,
      ),
      const Gap(8),
    ];

    if (isDesktopPlatform()) {
      return Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.escape): const PopIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{PopIntent: PopAction(ref)},
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainer,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Column(
                  children: [
                    DragToMoveArea(
                      child: Platform.isMacOS
                          ? Stack(
                              alignment: Alignment.center,
                              children: [
                                if (isWideScreen(context))
                                  Row(
                                    children: [
                                      const Spacer(),
                                      ...pageActionsButton,
                                    ],
                                  )
                                else
                                  SizedBox(height: 32),
                                Text(
                                  'GroovyBox',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Row(
                                    children: [
                                      Image.asset(
                                        Theme.of(context).brightness ==
                                                Brightness.dark
                                            ? 'assets/images/icon-dark.png'
                                            : 'assets/images/icon.png',
                                        width: 20,
                                        height: 20,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        'GroovyBox',
                                        textAlign: TextAlign.start,
                                      ),
                                    ],
                                  ).padding(horizontal: 12, vertical: 5),
                                ),
                                ...pageActionsButton,
                                IconButton(
                                  icon: Icon(Symbols.minimize),
                                  onPressed: () => windowManager.minimize(),
                                  iconSize: 16,
                                  padding: EdgeInsets.all(8),
                                  constraints: BoxConstraints(),
                                  color: Theme.of(context).iconTheme.color,
                                ),
                                IconButton(
                                  icon: Icon(
                                    isMaximized.value
                                        ? Symbols.fullscreen_exit
                                        : Symbols.fullscreen,
                                  ),
                                  onPressed: () async {
                                    if (await windowManager.isMaximized()) {
                                      windowManager.restore();
                                    } else {
                                      windowManager.maximize();
                                    }
                                  },
                                  iconSize: 16,
                                  padding: EdgeInsets.all(8),
                                  constraints: BoxConstraints(),
                                  color: Theme.of(context).iconTheme.color,
                                ),
                                IconButton(
                                  icon: Icon(Symbols.close),
                                  onPressed: () => windowManager.close(),
                                  iconSize: 16,
                                  padding: EdgeInsets.all(8),
                                  constraints: BoxConstraints(),
                                  color: Theme.of(context).iconTheme.color,
                                ),
                              ],
                            ),
                    ),
                    Expanded(
                      child: Stack(
                        children: [
                          // Main Content
                          Positioned.fill(child: child),
                          // Mini Player
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: MiniPlayer(),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      child: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.escape): const PopIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{PopIntent: PopAction(ref)},
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: child),
              Positioned(left: 0, right: 0, bottom: 0, child: MiniPlayer()),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _batchImportLyricsFromPaths(
    BuildContext context,
    WidgetRef ref,
    List<String> lyricsPaths,
  ) async {
    if (lyricsPaths.isEmpty) return;

    final repo = ref.read(trackRepositoryProvider.notifier);
    final tracks = await repo.getAllTracks();

    int matched = 0;
    int notMatched = 0;

    for (final path in lyricsPaths) {
      final file = File(path);
      final content = await file.readAsString();
      final filename = p.basename(path);

      // Get basename without extension for matching
      final baseName = filename
          .replaceAll(RegExp(r'\.(lrc|srt|txt)$', caseSensitive: false), '')
          .toLowerCase();

      // Try to find a matching track by title
      final matchingTrack = tracks.where((t) {
        final trackTitle = t.title.toLowerCase();
        return trackTitle == baseName ||
            trackTitle.contains(baseName) ||
            baseName.contains(trackTitle);
      }).firstOrNull;

      if (matchingTrack != null) {
        final lyricsData = LyricsParser.parse(content, filename);
        await repo.updateLyrics(matchingTrack.id, lyricsData.toJsonString());
        matched++;
      } else {
        notMatched++;
      }
    }

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Batch import complete: $matched matched, $notMatched not matched',
        ),
      ),
    );
  }
}
