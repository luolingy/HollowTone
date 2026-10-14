import 'package:easy_localization/easy_localization.dart';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show Uint8List;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hollowtone/data/db.dart';
import 'package:hollowtone/data/playlist_repository.dart';
import 'package:hollowtone/data/track_repository.dart';

import 'package:hollowtone/logic/lyrics_parser.dart';
import 'package:hollowtone/logic/online_metadata_service.dart';
import 'package:hollowtone/logic/window_helpers.dart';
import 'package:hollowtone/providers/audio_provider.dart';
import 'package:hollowtone/providers/settings_provider.dart';
import 'package:hollowtone/providers/watch_folder_provider.dart';
import 'package:hollowtone/router.dart';
import 'package:hollowtone/ui/tabs/albums_tab.dart';
import 'package:hollowtone/ui/tabs/playlists_tab.dart';
import 'package:hollowtone/ui/widgets/track_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path/path.dart' as p;
import 'package:styled_widget/styled_widget.dart';

/// Cache of lower-cased lyric text per track, so typing in the search box
/// does not re-parse every track's lyrics JSON on each keystroke.
final Map<String, String> _lyricsSearchCache = <String, String>{};

String? lyricsSearchText(Track track) {
  final lyrics = track.lyrics;
  if (lyrics == null) return null;
  final key = '${track.id}:${lyrics.length}';
  final cached = _lyricsSearchCache[key];
  if (cached != null) return cached;
  try {
    final data = LyricsData.fromJsonString(lyrics);
    // Keep the cache bounded; a simple reset is fine for this use case.
    if (_lyricsSearchCache.length > 800) _lyricsSearchCache.clear();
    final blob = data.lines.map((line) => line.text).join('\n').toLowerCase();
    _lyricsSearchCache[key] = blob;
    return blob;
  } catch (_) {
    return null;
  }
}

class LibraryScreen extends HookConsumerWidget {
  const LibraryScreen({super.key});

  static const List<String> audioExtensions = [
    'mp3',
    'm4a',
    'wav',
    'flac',
    'aac',
    'ogg',
    'wma',
    'm4p',
    'aiff',
    'au',
    'dss',
  ];

  static const List<String> lyricsExtensions = ['lrc', 'srt', 'txt'];

  static const List<String> imageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
  ];

  static const List<String> allAllowedExtensions = [
    ...audioExtensions,
    ...lyricsExtensions,
    ...imageExtensions,
  ];

  /// Shared action row for selection mode: select all, invert, add to queue,
  /// and an overflow menu with add-to-playlist / delete.
  List<Widget> _buildSelectionActions(
    BuildContext context,
    WidgetRef ref,
    ValueNotifier<Set<int>> selectedTrackIds,
    ValueNotifier<List<int>> availableTrackIds,
    VoidCallback clearSelection,
  ) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    final availableSet = availableTrackIds.value.toSet();
    final allSelected =
        availableSet.isNotEmpty && selectedTrackIds.value.containsAll(availableSet);

    Future<void> addToQueue() async {
      final ids = selectedTrackIds.value.intersection(
        availableTrackIds.value.toSet(),
      );
      if (ids.isEmpty) return;
      final trackRepo = ref.read(trackRepositoryProvider.notifier);
      final all = await trackRepo.getAllTracks();
      final tracks = all.where((t) => ids.contains(t.id)).toList();
      await ref.read(audioHandlerProvider).addTracksToQueue(tracks);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${'added'.tr()} ${tracks.length} ${'tracks'.tr()} ${'to'.tr()} ${'queue'.tr()}',
          ),
        ),
      );
    }

    return [
      IconButton(
        icon: Icon(allSelected ? Symbols.clear : Symbols.done_all),
        tooltip: allSelected ? 'clear'.tr() : 'selectAll'.tr(),
        color: onPrimary,
        onPressed: () {
          selectedTrackIds.value = allSelected ? <int>{} : availableSet;
        },
      ),
      IconButton(
        icon: const Icon(Symbols.difference),
        tooltip: 'invertSelection'.tr(),
        color: onPrimary,
        onPressed: () {
          final current = selectedTrackIds.value;
          selectedTrackIds.value = availableTrackIds.value
              .where((id) => !current.contains(id))
              .toSet();
        },
      ),
      IconButton(
        icon: const Icon(Symbols.queue_music),
        tooltip: 'addToQueue'.tr(),
        color: onPrimary,
        onPressed: addToQueue,
      ),
      PopupMenuButton<String>(
        icon: Icon(Symbols.more_vert, color: onPrimary),
        onSelected: (value) {
          if (value == 'playlist') {
            _batchAddToPlaylist(
              context,
              ref,
              selectedTrackIds.value.toList(),
              clearSelection,
            );
          } else if (value == 'delete') {
            _batchDelete(
              context,
              ref,
              selectedTrackIds.value.toList(),
              clearSelection,
            );
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(
            value: 'playlist',
            child: Row(
              spacing: 12,
              children: [
                const Icon(Symbols.playlist_add),
                Text('addToPlaylist'.tr()),
              ],
            ),
          ),
          PopupMenuItem(
            value: 'delete',
            child: Row(
              spacing: 12,
              children: [
                const Icon(Symbols.delete, color: Colors.red),
                Text('delete'.tr(), style: const TextStyle(color: Colors.red)),
              ],
            ),
          ),
        ],
      ),
      const Gap(8),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // We can define a stream provider locally or in repository file.
    // For now, using StreamBuilder is easiest since `watchAllTracks` returns a Stream.
    // Or better: `ref.watch(trackListStreamProvider)`.

    // Let's assume we use StreamBuilder for now to avoid creating another file/provider on the fly.
    final repo = ref.watch(trackRepositoryProvider.notifier);
    final selectedTrackIds = useState<Set<int>>({});
    final searchQuery = useState<String>('');
    // Track ids currently visible in the tracks tab (after search filtering);
    // feeds select-all / invert-selection actions.
    final availableTrackIds = useState<List<int>>([]);
    final isSelectionMode = selectedTrackIds.value.isNotEmpty;
    final isLargeScreen = MediaQuery.of(context).size.width > 600;
    final isExtraLargeScreen = MediaQuery.of(context).size.width > 800;
    final selectedTab = isLargeScreen ? useState<int>(0) : null;

    void toggleSelection(int id) {
      final newSet = Set<int>.from(selectedTrackIds.value);
      if (newSet.contains(id)) {
        newSet.remove(id);
      } else {
        newSet.add(id);
      }
      selectedTrackIds.value = newSet;
    }

    void clearSelection() {
      selectedTrackIds.value = {};
    }

    if (isLargeScreen) {
      return Scaffold(
        appBar: isSelectionMode
            ? AppBar(
                leading: IconButton(
                  icon: const Icon(Symbols.close),
                  color: Theme.of(context).colorScheme.onPrimary,
                  onPressed: clearSelection,
                ),
                title: Text(
                  'selected'.tr(
                    args: [selectedTrackIds.value.length.toString()],
                  ),
                ).textColor(Theme.of(context).colorScheme.onPrimary),
                backgroundColor: Theme.of(context).colorScheme.primary,
                actions: _buildSelectionActions(
                  context,
                  ref,
                  selectedTrackIds,
                  availableTrackIds,
                  clearSelection,
                ),
              )
            : (isDesktopPlatform()
                  ? null
                  : AppBar(
                      backgroundColor: Theme.of(
                        context,
                      ).colorScheme.surfaceContainer,
                      elevation: 0,
                      scrolledUnderElevation: 0,
                      title: isLargeScreen
                          ? Row(
                              children: [
                                const Gap(4),
                                Image.asset(
                                  Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? 'assets/images/icon-dark.png'
                                      : 'assets/images/icon.png',
                                  width: 32,
                                  height: 32,
                                ).clipRRect(all: 8).padding(vertical: 16),
                                const Gap(12),
                                Text(
                                  tr('hollowTone'),
                                  style: TextStyle(fontSize: 18),
                                ),
                              ],
                            )
                          : Text('library'.tr()),
                      actions: [
                        IconButton(
                          onPressed: () {
                            ref.read(routerProvider).push(AppRoutes.settings);
                          },
                          icon: const Icon(Symbols.settings),
                        ),
                        IconButton(
                          icon: const Icon(Symbols.add_circle_outline),
                          tooltip: 'importFiles'.tr(),
                          onPressed: () async {
                            final result = await FilePicker.platform.pickFiles(
                              type: FileType.any,
                              allowMultiple: true,
                            );
                            if (result != null && result.files.isNotEmpty) {
                              final paths = result.files
                                  .map((f) => f.path)
                                  .whereType<String>()
                                  .toList();
                              if (paths.isNotEmpty) {
                                String extOf(String path) => p
                                    .extension(path)
                                    .toLowerCase()
                                    .replaceFirst('.', '');
                                final audioPaths = paths
                                    .where(
                                      (path) => audioExtensions.contains(
                                        extOf(path),
                                      ),
                                    )
                                    .toList();
                                final lyricsPaths = paths
                                    .where(
                                      (path) => lyricsExtensions.contains(
                                        extOf(path),
                                      ),
                                    )
                                    .toList();
                                final coverPaths = paths
                                    .where(
                                      (path) => imageExtensions.contains(
                                        extOf(path),
                                      ),
                                    )
                                    .toList();

                                // Import tracks first, then auto-assign the
                                // selected lyrics/covers by file name.
                                if (audioPaths.isNotEmpty) {
                                  await repo.importFiles(audioPaths);
                                }

                                if (!context.mounted) return;
                                if (lyricsPaths.isNotEmpty ||
                                    coverPaths.isNotEmpty) {
                                  final applied = await repo
                                      .applySidecarsByFilename(
                                        lyricPaths: lyricsPaths,
                                        coverPaths: coverPaths,
                                      );
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'sidecarsApplied'.tr(
                                          args: [applied.toString()],
                                        ),
                                      ),
                                    ),
                                  );
                                }
                              }
                            }
                          },
                        ),
                        const Gap(8),
                      ],
                    )),
        body: Material(
          color: Theme.of(context).colorScheme.surfaceContainer,
          child: Row(
            children: [
              NavigationRail(
                backgroundColor: Colors.transparent,
                extended: isExtraLargeScreen,
                selectedIndex: selectedTab!.value,
                onDestinationSelected: (index) => selectedTab.value = index,
                destinations: [
                  NavigationRailDestination(
                    icon: Icon(Symbols.audiotrack),
                    label: Text('tracks'.tr()),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Symbols.album),
                    label: Text('albums'.tr()),
                  ),
                  NavigationRailDestination(
                    icon: Icon(Symbols.queue_music),
                    label: Text('playlists'.tr()),
                  ),
                ],
              ),
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                  ),
                  child: Material(
                    color: Theme.of(context).colorScheme.surface,
                    child: _buildTabContent(
                      selectedTab.value,
                      ref,
                      repo,
                      selectedTrackIds,
                      availableTrackIds,
                      searchQuery,
                      toggleSelection,
                      isSelectionMode,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      return DefaultTabController(
        length: 3,
        child: Scaffold(
          appBar: isSelectionMode
              ? AppBar(
                  leading: IconButton(
                    icon: const Icon(Symbols.close),
                    color: Theme.of(context).colorScheme.onPrimary,
                    onPressed: clearSelection,
                  ),
                  title: Text(
                    'selected'.tr(
                      args: [selectedTrackIds.value.length.toString()],
                    ),
                  ).textColor(Theme.of(context).colorScheme.onPrimary),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  actions: _buildSelectionActions(
                    context,
                    ref,
                    selectedTrackIds,
                    availableTrackIds,
                    clearSelection,
                  ),
                )
              : AppBar(
                  centerTitle: true,
                  title: Text('library'.tr()),
                  bottom: TabBar(
                    tabs: [
                      Tab(text: 'tracks'.tr(), icon: Icon(Symbols.audiotrack)),
                      Tab(text: 'albums'.tr(), icon: Icon(Symbols.album)),
                      Tab(
                        text: 'playlists'.tr(),
                        icon: Icon(Symbols.queue_music),
                      ),
                    ],
                  ),
                  actions: [
                    IconButton(
                      onPressed: () {
                        ref.read(routerProvider).push(AppRoutes.settings);
                      },
                      icon: const Icon(Symbols.settings),
                    ),
                    IconButton(
                      icon: const Icon(Symbols.add_circle_outline),
                      tooltip: 'importFiles'.tr(),
                      onPressed: () async {
                        final result = await FilePicker.platform.pickFiles(
                          type: FileType.any,
                          allowMultiple: true,
                        );
                        if (result != null && result.files.isNotEmpty) {
                          final paths = result.files
                              .map((f) => f.path)
                              .whereType<String>()
                              .toList();
                          if (paths.isNotEmpty) {
                            String extOf(String path) => p
                                .extension(path)
                                .toLowerCase()
                                .replaceFirst('.', '');
                            final audioPaths = paths
                                .where(
                                  (path) =>
                                      audioExtensions.contains(extOf(path)),
                                )
                                .toList();
                            final lyricsPaths = paths
                                .where(
                                  (path) =>
                                      lyricsExtensions.contains(extOf(path)),
                                )
                                .toList();
                            final coverPaths = paths
                                .where(
                                  (path) =>
                                      imageExtensions.contains(extOf(path)),
                                )
                                .toList();

                            // Import tracks first, then auto-assign the
                            // selected lyrics/covers by file name.
                            if (audioPaths.isNotEmpty) {
                              await repo.importFiles(audioPaths);
                            }

                            if (!context.mounted) return;
                            if (lyricsPaths.isNotEmpty ||
                                coverPaths.isNotEmpty) {
                              final applied = await repo
                                  .applySidecarsByFilename(
                                    lyricPaths: lyricsPaths,
                                    coverPaths: coverPaths,
                                  );
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'sidecarsApplied'.tr(
                                      args: [applied.toString()],
                                    ),
                                  ),
                                ),
                              );
                            }
                          }
                        }
                      },
                    ),
                    const Gap(8),
                  ],
                ),
          body: TabBarView(
            children: [
              _buildTracksTab(
                ref,
                repo,
                selectedTrackIds,
                availableTrackIds,
                searchQuery,
                toggleSelection,
                isSelectionMode,
              ),
              const AlbumsTab(),
              const PlaylistsTab(),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildTracksTab(
    WidgetRef ref,
    dynamic repo,
    ValueNotifier<Set<int>> selectedTrackIds,
    ValueNotifier<List<int>> availableTrackIds,
    ValueNotifier<String> searchQuery,
    void Function(int) toggleSelection,
    bool isSelectionMode,
  ) {
    return StreamBuilder<List<Track>>(
      stream: repo.watchAllTracks(),
      builder: (context, snapshot) {
        // Calculate hintText
        String hintText;
        if (!snapshot.hasData || snapshot.hasError) {
          hintText = 'searchTracks'.tr();
        } else {
          final tracks = snapshot.data!;
          final totalTracks = tracks.length;
          if (searchQuery.value.isEmpty) {
            hintText = 'searchTracksWithCount'.tr(
              args: [totalTracks.toString()],
            );
          } else {
            final query = searchQuery.value.toLowerCase();
            final filteredCount = tracks.where((track) {
              if (track.title.toLowerCase().contains(query)) return true;
              if (track.artist?.toLowerCase().contains(query) ?? false) {
                return true;
              }
              if (track.album?.toLowerCase().contains(query) ?? false) {
                return true;
              }
              final blob = lyricsSearchText(track);
              if (blob != null && blob.contains(query)) return true;
              return false;
            }).length;
            hintText = 'searchTracksFiltered'
                .tr(args: [filteredCount.toString(), totalTracks.toString()]);
          }
        }

        // Determine main content
        Widget mainContent;
        if (snapshot.hasError) {
          mainContent = Center(child: Text('Error: ${snapshot.error}'));
        } else if (!snapshot.hasData) {
          mainContent = const Center(child: CircularProgressIndicator());
        } else {
          final tracks = snapshot.data!;
          if (tracks.isEmpty) {
            mainContent = Center(child: Text('noTracksYet'.tr()));
          } else {
            List<Track> filteredTracks;
            if (searchQuery.value.isEmpty) {
              filteredTracks = tracks;
            } else {
              final query = searchQuery.value.toLowerCase();
              filteredTracks = tracks.where((track) {
                if (track.title.toLowerCase().contains(query)) return true;
                if (track.artist?.toLowerCase().contains(query) ?? false) {
                  return true;
                }
                if (track.album?.toLowerCase().contains(query) ?? false) {
                  return true;
                }
                final blob = lyricsSearchText(track);
                if (blob != null && blob.contains(query)) return true;
                return false;
              }).toList();
            }

            if (filteredTracks.isEmpty && searchQuery.value.isNotEmpty) {
              mainContent = Center(child: Text('noTracksMatchSearch'.tr()));
            } else {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                availableTrackIds.value = filteredTracks
                    .map((t) => t.id)
                    .toList(growable: false);
              });
              mainContent = ListView.builder(
                padding: EdgeInsets.only(
                  bottom: 72 + MediaQuery.paddingOf(context).bottom,
                  top: 80,
                ),
                itemCount: filteredTracks.length,
                itemBuilder: (context, index) {
                  final track = filteredTracks[index];
                  final isSelected = selectedTrackIds.value.contains(track.id);

                  if (isSelectionMode) {
                    return ListTile(
                      selected: isSelected,
                      selectedTileColor: Colors.white10,
                      leading: Checkbox(
                        value: isSelected,
                        onChanged: (_) => toggleSelection(track.id),
                      ),
                      title: Text(
                        track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${track.artist ?? 'unknownArtist'.tr()} - ${_formatDuration(track.duration)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => toggleSelection(track.id),
                    );
                  }

                  return Dismissible(
                    key: Key('track_${track.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: Colors.red,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Symbols.delete, color: Colors.white),
                    ),
                    confirmDismiss: (direction) async {
                      return await showDialog(
                        context: context,
                        builder: (context) {
                          return AlertDialog(
                            title: Text('deleteTrack'.tr()),
                            content: Text(
                              'confirmDeleteTrack'.tr(args: [track.title]),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: Text('cancel'.tr()),
                              ),
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.red,
                                ),
                                child: Text('delete'.tr()),
                              ),
                            ],
                          );
                        },
                      );
                    },
                    onDismissed: (direction) {
                      ref
                          .read(trackRepositoryProvider.notifier)
                          .deleteTrack(track.id);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('deletedTrack'.tr(args: [track.title])),
                        ),
                      );
                    },
                    child: TrackTile(
                      track: track,
                      showTrailingIcon: true,
                      onTrailingPressed: () =>
                          _showTrackOptions(context, ref, track),
                      onLongPress: () => toggleSelection(track.id),
                      onTap: () {
                        final loadingNotifier = ref.read(
                          remoteTrackLoadingProvider.notifier,
                        );
                        final audio = ref.read(audioHandlerProvider);
                        loadingNotifier.setLoading(true);
                        audio.playTrack(track).then((_) {
                          loadingNotifier.setLoading(false);
                        });
                      },
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                    ),
                  );
                },
              );
            }
          }
        }

        return Stack(
          children: [
            mainContent,
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                child: SearchBar(
                  onChanged: (value) => searchQuery.value = value,
                  hintText: hintText,
                  leading: const Icon(Symbols.search),
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 24),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTabContent(
    int index,
    WidgetRef ref,
    dynamic repo,
    ValueNotifier<Set<int>> selectedTrackIds,
    ValueNotifier<List<int>> availableTrackIds,
    ValueNotifier<String> searchQuery,
    void Function(int) toggleSelection,
    bool isSelectionMode,
  ) {
    switch (index) {
      case 0:
        return _buildTracksTab(
          ref,
          repo,
          selectedTrackIds,
          availableTrackIds,
          searchQuery,
          toggleSelection,
          isSelectionMode,
        );
      case 1:
        return const AlbumsTab();
      case 2:
        return const PlaylistsTab();
      default:
        return const SizedBox();
    }
  }

  void _showTrackOptions(BuildContext context, WidgetRef ref, Track track) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        // Clear the mini player bar (72px + system inset) so the last menu
        // entries stay tappable.
        final bottomClearance =
            72.0 + MediaQuery.of(context).viewPadding.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottomClearance),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Symbols.playlist_add),
                title: Text('addToPlaylist'.tr()),
                onTap: () {
                  Navigator.pop(context);
                  _showAddToPlaylistDialog(context, ref, track);
                },
              ),
              ListTile(
                leading: const Icon(Symbols.info),
                title: Text('viewDetails'.tr()),
                onTap: () {
                  Navigator.pop(context);
                  _showTrackDetails(context, ref, track);
                },
              ),
              ListTile(
                leading: const Icon(Symbols.edit),
                title: Text('editMetadata'.tr()),
                onTap: () {
                  Navigator.pop(context);
                  _showEditDialog(context, ref, track);
                },
              ),
              ListTile(
                leading: const Icon(Symbols.image),
                title: Text('importCover'.tr()),
                onTap: () {
                  Navigator.pop(context);
                  _importCoverForTrack(context, ref, track);
                },
              ),
              ListTile(
                leading: const Icon(Symbols.travel_explore),
                title: Text('onlineMatch'.tr()),
                onTap: () {
                  Navigator.pop(context);
                  _onlineMatchTrack(context, ref, track);
                },
              ),
              ListTile(
                leading: const Icon(Symbols.lyrics),
                title: Text('importLyrics'.tr()),
                onTap: () {
                  Navigator.pop(context);
                  _importLyricsForTrack(context, ref, track);
                },
              ),
              ListTile(
                leading: const Icon(Symbols.delete, color: Colors.red),
                title: Text(
                  'deleteTrack'.tr(),
                  style: TextStyle(color: Colors.red),
                ),
                onTap: () {
                  Navigator.pop(context);
                  ref
                      .read(trackRepositoryProvider.notifier)
                      .deleteTrack(track.id);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddToPlaylistDialog(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) {
    final screenSize = MediaQuery.of(context).size;
    showDialog(
      context: context,
      builder: (context) {
        // Fetch playlists
        // Note: Using a hook/provider inside dialog builder might need a Consumer or similar if stream updates.
        // For simplicity, we'll assume the user wants to pick from *current* playlists.
        // Or we can use a Consumer widget inside the dialog.
        return AlertDialog(
          title: Text('addToPlaylist'.tr()),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: screenSize.width * 0.8,
              maxHeight: screenSize.height * 0.6,
            ),
            child: Consumer(
              builder: (context, ref, child) {
                final playlistsAsync = ref
                    .watch(playlistRepositoryProvider.notifier)
                    .watchAllPlaylists();
                return StreamBuilder<List<Playlist>>(
                  stream: playlistsAsync,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final playlists = snapshot.data!;
                    if (playlists.isEmpty) {
                      return Text('noPlaylistsAvailable'.tr());
                    }

                    return SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: playlists.map((playlist) {
                          return ListTile(
                            title: Text(playlist.name),
                            onTap: () {
                              ref
                                  .read(playlistRepositoryProvider.notifier)
                                  .addToPlaylist(playlist.id, track.id);
                              Navigator.pop(context);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'addedToPlaylist'.tr(args: [playlist.name]),
                                  ),
                                ),
                              );
                            },
                          );
                        }).toList(),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr()),
            ),
          ],
        );
      },
    );
  }

  void _showTrackDetails(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    // Try to get file info
    String fileSize = 'unknown'.tr();
    String libraryName = 'unknown'.tr();
    String dateAdded = 'unknown'.tr();

    try {
      final file = File(track.path);
      if (await file.exists()) {
        final stat = await file.stat();
        final sizeInMB = (stat.size / (1024 * 1024)).toStringAsFixed(2);
        fileSize = '$sizeInMB MB';
        dateAdded = stat.modified.toString().split(
          ' ',
        )[0]; // Just the date part
      }
    } catch (e) {
      // Ignore file access errors
    }

    // Try to find which library this track belongs to
    final watchFoldersAsync = ref.read(watchFoldersProvider);
    watchFoldersAsync.whenData((folders) {
      for (final folder in folders) {
        if (track.path.startsWith(folder.path)) {
          libraryName = folder.name;
          break;
        }
      }
    });

    if (!context.mounted) return;

    final screenSize = MediaQuery.sizeOf(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('trackDetails'.tr()),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: screenSize.width * 0.8),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDetailRow('title'.tr(), track.title),
                _buildDetailRow('artist'.tr(), track.artist ?? 'Unknown'),
                _buildDetailRow('album'.tr(), track.album ?? 'Unknown'),
                _buildDetailRow(
                  'duration'.tr(),
                  _formatDuration(track.duration),
                ),
                _buildDetailRow('fileSize'.tr(), fileSize),
                _buildDetailRow('library'.tr(), libraryName),
                _buildDetailRow('filePath'.tr(), track.path),
                _buildDetailRow('dateAdded'.tr(), dateAdded),
                if (track.artUri != null)
                  _buildDetailRow('albumArt'.tr(), 'Present'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('close'.tr()),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(color: Colors.grey)),
          ),
        ],
      ),
    );
  }

  Future<void> _importCoverForTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null) return;

    try {
      await ref
          .read(trackRepositoryProvider.notifier)
          .updateTrackCover(track.id, bytes);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('coverUpdated'.tr(args: [track.title]))),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('errorUpdatingCover'.tr(args: [e.toString()]))),
      );
    }
  }

  /// Searches the configured online channel (NetEase / QQ Music) and lets
  /// the user apply metadata, cover art and lyrics to [track].
  Future<void> _onlineMatchTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final channel = ref.read(metadataChannelProvider);
    final impl = metadataChannelImpl(
      channel == MetadataChannel.qq
          ? OnlineChannel.qq
          : OnlineChannel.netease,
    );

    final match = await showDialog<OnlineMatch>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('onlineMatch'.tr()),
          content: SizedBox(
            width: 420,
            height: 320,
            child: FutureBuilder<List<OnlineMatch>>(
              future: impl.search(track.title, artist: track.artist),
              builder: (innerContext, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const Gap(12),
                        Text('onlineSearching'.tr()),
                      ],
                    ),
                  );
                }
                final results = snapshot.data ?? const <OnlineMatch>[];
                if (results.isEmpty) {
                  return Center(child: Text('noOnlineResults'.tr()));
                }
                return ListView.builder(
                  itemCount: results.length,
                  itemBuilder: (itemContext, index) {
                    final item = results[index];
                    return ListTile(
                      dense: true,
                      title: Text(item.title),
                      subtitle: Text(
                        '${item.artist}${item.album == null ? '' : ' - ${item.album}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(dialogContext, item),
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, null),
              child: Text('cancel'.tr()),
            ),
          ],
        );
      },
    );
    if (match == null || !context.mounted) return;

    // Choose what to apply.
    var fillInfo = true;
    var downloadCover = true;
    var replaceLyrics = false;
    Uint8List? coverBytes;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            return AlertDialog(
              title: Text(match.title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    value: fillInfo,
                    onChanged: (v) =>
                        setDialogState(() => fillInfo = v ?? false),
                    title: Text('matchApplyInfo'.tr()),
                  ),
                  CheckboxListTile(
                    value: downloadCover,
                    onChanged: (v) =>
                        setDialogState(() => downloadCover = v ?? false),
                    title: Text('matchDownloadCover'.tr()),
                  ),
                  CheckboxListTile(
                    value: replaceLyrics,
                    onChanged: (v) =>
                        setDialogState(() => replaceLyrics = v ?? false),
                    title: Text('matchReplaceLyrics'.tr()),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: Text('cancel'.tr()),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: Text('apply'.tr()),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != true || !context.mounted) return;

    // Fetch and normalize lyrics to LyricsData JSON before persisting, so
    // consumers reading via LyricsData.fromJsonString always get valid data.
    String? lyricsJson;
    if (replaceLyrics) {
      final lyricText = await impl.fetchLyric(match.songId);
      if (!context.mounted) return;
      if (lyricText == null || lyricText.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('noOnlineResults'.tr())),
        );
        return;
      }
      lyricsJson =
          LyricsParser.parse(lyricText, '${match.title}.lrc').toJsonString();
    }
    if (!context.mounted) return;
    if (downloadCover) coverBytes = await impl.downloadCover(match.songId);

    await ref
        .read(trackRepositoryProvider.notifier)
        .applyOnlineMatch(
          trackId: track.id,
          match: match,
          coverBytes: coverBytes,
          lyrics: lyricsJson,
          fillInfo: fillInfo,
          downloadCover: downloadCover && coverBytes != null,
          replaceLyrics: replaceLyrics,
        );

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('onlineMatchDone'.tr())),
    );
  }

  void _showEditDialog(BuildContext context, WidgetRef ref, Track track) {
    final titleController = TextEditingController(text: track.title);
    final artistController = TextEditingController(text: track.artist);
    final albumController = TextEditingController(text: track.album);
    final screenSize = MediaQuery.of(context).size;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('editTrack'.tr()),
        content: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: screenSize.width * 0.8),
          child: Column(
            spacing: 16,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                decoration: InputDecoration(labelText: 'title'.tr()),
              ),
              TextField(
                controller: artistController,
                decoration: InputDecoration(labelText: 'artist'.tr()),
              ),
              TextField(
                controller: albumController,
                decoration: InputDecoration(labelText: 'album'.tr()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('cancel'.tr()),
          ),
          TextButton(
            onPressed: () {
              ref
                  .read(trackRepositoryProvider.notifier)
                  .updateMetadata(
                    trackId: track.id,
                    title: titleController.text,
                    artist: artistController.text,
                    album: albumController.text,
                  );
              Navigator.pop(context);
            },
            child: Text('save'.tr()),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int? durationMs) {
    if (durationMs == null) return '--:--';
    final d = Duration(milliseconds: durationMs);
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  void _batchAddToPlaylist(
    BuildContext context,
    WidgetRef ref,
    List<int> trackIds,
    VoidCallback onSuccess,
  ) {
    final screenSize = MediaQuery.of(context).size;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('addToPlaylist'.tr()),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: screenSize.width * 0.8,
              maxHeight: screenSize.height * 0.6,
            ),
            child: Consumer(
              builder: (context, ref, child) {
                final playlistsAsync = ref
                    .watch(playlistRepositoryProvider.notifier)
                    .watchAllPlaylists();
                return StreamBuilder<List<Playlist>>(
                  stream: playlistsAsync,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final playlists = snapshot.data!;
                    if (playlists.isEmpty) {
                      return Text('noPlaylistsAvailable'.tr());
                    }

                    return SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: playlists.map((playlist) {
                          return ListTile(
                            title: Text(playlist.name),
                            onTap: () async {
                              final repo = ref.read(
                                playlistRepositoryProvider.notifier,
                              );
                              for (final id in trackIds) {
                                await repo.addToPlaylist(playlist.id, id);
                              }
                              if (!context.mounted) return;
                              Navigator.pop(context);
                              onSuccess();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    '${'added'.tr()} ${trackIds.length} ${'tracks'.tr()} ${'to'.tr()} ${playlist.name}',
                                  ),
                                ),
                              );
                            },
                          );
                        }).toList(),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('cancel'.tr()),
            ),
          ],
        );
      },
    );
  }

  void _batchDelete(
    BuildContext context,
    WidgetRef ref,
    List<int> trackIds,
    VoidCallback onSuccess,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('deleteTracks'.tr()),
        content: Text(
          '${'confirmDelete'.tr()} ${trackIds.length} ${'tracks'.tr()}? '
          '${'thisWillRemoveThemFromYourDevice'.tr()}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('cancel'.tr()),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text('delete'.tr()),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final repo = ref.read(trackRepositoryProvider.notifier);
      for (final id in trackIds) {
        await repo.deleteTrack(id);
      }
      onSuccess();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${'deleted'.tr()} ${trackIds.length} ${'tracks'.tr()}',
          ),
        ),
      );
    }
  }

  Future<void> _importLyricsForTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['lrc', 'srt', 'txt'],
      allowMultiple: false,
    );

    if (result != null && result.files.isNotEmpty) {
      final file = File(result.files.first.path!);
      final content = await file.readAsString();
      final filename = result.files.first.name;

      final lyricsData = LyricsParser.parse(content, filename);
      final lyricsJson = lyricsData.toJsonString();

      await ref
          .read(trackRepositoryProvider.notifier)
          .updateLyrics(track.id, lyricsJson);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${'imported'.tr()} ${lyricsData.lines.length} ${'lyricsLines'.tr()} for "${track.title}"',
          ),
        ),
      );
    }
  }

}
