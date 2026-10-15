import 'package:easy_localization/easy_localization.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:gap/gap.dart';
import 'package:hollowtone/data/db.dart';
import 'package:hollowtone/data/playlist_repository.dart';

import 'package:hollowtone/providers/audio_provider.dart';
import 'package:hollowtone/providers/remote_provider.dart';
import 'package:hollowtone/ui/widgets/track_tile.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:styled_widget/styled_widget.dart';

/// Shifts every selected position one slot toward [up] while keeping the
/// relative order inside the selection and inside the rest of the list.
List<int> _shiftedOrder(int n, Set<int> selected, bool up) {
  final order = List<int>.generate(n, (i) => i);
  if (up) {
    for (var i = 0; i < order.length; i++) {
      if (selected.contains(order[i]) &&
          i > 0 &&
          !selected.contains(order[i - 1])) {
        final t = order[i];
        order[i] = order[i - 1];
        order[i - 1] = t;
      }
    }
  } else {
    for (var i = order.length - 1; i >= 0; i--) {
      if (selected.contains(order[i]) &&
          i < order.length - 1 &&
          !selected.contains(order[i + 1])) {
        final t = order[i];
        order[i] = order[i + 1];
        order[i + 1] = t;
      }
    }
  }
  return order;
}

class PlaylistDetailScreen extends HookConsumerWidget {
  final Playlist playlist;

  const PlaylistDetailScreen({super.key, required this.playlist});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(playlistRepositoryProvider.notifier);
    final tracksAsync = repo.watchPlaylistTracks(playlist.id);
    final selectedIds = useState<Set<int>>({});

    // Responsive breakpoints
    final screenWidth = MediaQuery.sizeOf(context).width;
    final isLargeScreen = screenWidth > 900;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(pinned: true, title: Text(playlist.name)),
          // Content section with constrained width
          SliverToBoxAdapter(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isLargeScreen ? 800 : double.infinity,
                ),
                child: StreamBuilder<List<Track>>(
                  stream: tracksAsync,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const SizedBox(
                        height: 200,
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final tracks = snapshot.data!;
                    if (tracks.isEmpty) {
                      return SizedBox(
                        height: 200,
                        child: Center(
                          child: Text('noTracksInPlaylist'.tr()),
                        ),
                      );
                    }

                    final selecting = selectedIds.value.isNotEmpty;

                    Future<void> moveSelected(bool up) async {
                      final sel = selectedIds.value;
                      if (sel.isEmpty) return;
                      final ids = tracks.map((t) => t.id).toList();
                      final positions = <int>{
                        for (var i = 0; i < ids.length; i++)
                          if (sel.contains(ids[i])) i,
                      };
                      final order = _shiftedOrder(ids.length, positions, up);
                      await repo.reorderPlaylistTracks(
                        playlist.id,
                        [for (final i in order) ids[i]],
                      );
                    }

                    return Column(
                      children: [
                        // Action buttons
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 360),
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Column(
                              spacing: 12,
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: FilledButton.icon(
                                    onPressed: () {
                                      _playPlaylist(ref, tracks);
                                    },
                                    icon: const Icon(Symbols.play_arrow),
                                    label: Text('playAll'.tr()),
                                  ),
                                ),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      _addToQueue(ref, tracks);
                                    },
                                    icon: const Icon(Symbols.queue_music),
                                    label: Text('addToQueue'.tr()),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Selection toolbar for batch moving
                        if (selecting)
                          Material(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.only(left: 16),
                                    child: Text(
                                      'selected'.tr(
                                        args: [
                                          selectedIds.value.length.toString(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Symbols.arrow_upward),
                                  tooltip: 'up'.tr(),
                                  onPressed: () => moveSelected(true),
                                ),
                                IconButton(
                                  icon: const Icon(Symbols.arrow_downward),
                                  tooltip: 'down'.tr(),
                                  onPressed: () => moveSelected(false),
                                ),
                                IconButton(
                                  icon: const Icon(Symbols.check),
                                  tooltip: 'done'.tr(),
                                  onPressed: () => selectedIds.value = {},
                                ),
                                const Gap(4),
                              ],
                            ),
                          ),
                        // Track list with drag-to-reorder custom ordering
                        ReorderableListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: !selecting,
                          onReorderItem: (oldIndex, newIndex) async {
                            final ids = tracks.map((t) => t.id).toList();
                            final moved = ids.removeAt(oldIndex);
                            ids.insert(newIndex, moved);
                            await repo.reorderPlaylistTracks(playlist.id, ids);
                          },
                          children: [
                            for (final index in List<int>.generate(
                              tracks.length,
                              (i) => i,
                            ))
                              KeyedSubtree(
                                key: ValueKey('playlist_track_${tracks[index].id}'),
                                child: _buildTrackTile(
                                  ref,
                                  tracks,
                                  index,
                                  isLargeScreen,
                                  selecting: selecting,
                                  isSelected: selectedIds.value.contains(
                                    tracks[index].id,
                                  ),
                                  onToggleSelected: () {
                                    final next = Set<int>.from(
                                      selectedIds.value,
                                    );
                                    final id = tracks[index].id;
                                    if (!next.remove(id)) next.add(id);
                                    selectedIds.value = next;
                                  },
                                ),
                              ),
                          ],
                        ),
                        // Gap for mini player
                        const Gap(80),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackTile(
    WidgetRef ref,
    List<Track> tracks,
    int index,
    bool isLargeScreen, {
    required bool selecting,
    required bool isSelected,
    required VoidCallback onToggleSelected,
  }) {
    final track = tracks[index];
    return TrackTile(
      track: track,
      leading: selecting
          ? Checkbox(value: isSelected, onChanged: (_) => onToggleSelected())
          : Text(
              '${index + 1}'.padLeft(2, '0'),
              style: const TextStyle(color: Colors.grey, fontSize: 16),
            ).padding(right: isLargeScreen ? 24 : 16),
      showTrailingIcon: false,
      onLongPress: onToggleSelected,
      onTap: () {
        if (selecting) {
          onToggleSelected();
        } else {
          _playPlaylist(ref, tracks, initialIndex: index);
        }
      },
      padding: EdgeInsets.symmetric(
        horizontal: isLargeScreen ? 24 : 16,
        vertical: 8,
      ),
    );
  }

  void _playPlaylist(
    WidgetRef ref,
    List<Track> tracks, {
    int initialIndex = 0,
  }) {
    final loadingNotifier = ref.read(remoteTrackLoadingProvider.notifier);
    final audioHandler = ref.read(audioHandlerProvider);
    loadingNotifier.setLoading(true);
    audioHandler.playTracks(tracks, initialIndex: initialIndex).then((_) {
      loadingNotifier.setLoading(false);
    });
  }

  void _addToQueue(WidgetRef ref, List<Track> tracks) async {
    final audioHandler = ref.read(audioHandlerProvider);

    // Add tracks one by one to avoid interrupting playback
    for (final track in tracks) {
      try {
        final mediaItem = await _trackToMediaItem(track);
        await audioHandler.addQueueItem(mediaItem);
      } catch (e) {
        debugPrint('Error adding track ${track.title} to queue: $e');
      }
    }
  }

  Future<MediaItem> _trackToMediaItem(Track track) async {
    Uri? artUri;

    if (track.artUri != null) {
      // Check if it's a network URL or local file path
      if (track.artUri!.startsWith('http://') ||
          track.artUri!.startsWith('https://')) {
        // For remote tracks, skip artwork to avoid authentication issues
        // The artwork will be loaded separately when the track is played
        if (!isRemoteStreamPath(track.path)) {
          // Only try to cache artwork for non-remote tracks
          try {
            final cachedFile = await DefaultCacheManager().getSingleFile(
              track.artUri!,
            );
            artUri = Uri.file(cachedFile.path);
          } catch (e) {
            // If caching fails, skip artwork
            debugPrint('Failed to cache artwork for ${track.title}: $e');
          }
        }
        // For remote tracks, don't set artUri to avoid authentication issues
      } else {
        // It's a local file path
        artUri = Uri.file(track.artUri!);
      }
    }

    return MediaItem(
      id: track.path,
      album: track.album,
      title: track.title,
      artist: track.artist,
      duration: track.duration != null
          ? Duration(milliseconds: track.duration!)
          : null,
      artUri: artUri,
    );
  }
}


