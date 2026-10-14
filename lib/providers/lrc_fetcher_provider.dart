import 'package:flutter/foundation.dart';
import 'package:hollowtone/data/db.dart' as db;
import 'package:drift/drift.dart' as drift;
import 'package:hollowtone/logic/lrc_providers.dart';
import 'package:hollowtone/logic/lyrics_parser.dart';
import 'package:hollowtone/providers/audio_provider.dart';
import 'package:hollowtone/providers/db_provider.dart';
import 'package:hollowtone/ui/screens/player_screen.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'lrc_fetcher_provider.g.dart';

@riverpod
class LyricsFetcher extends _$LyricsFetcher {
  @override
  LyricsFetcherState build() {
    return LyricsFetcherState();
  }

  Future<void> fetchLyricsForTrack({
    required int trackId,
    required String searchTerm,
    required LrcProvider provider,
    required String trackPath,
  }) async {
    debugPrint(
      'Fetching lyrics for track $trackId with search term: $searchTerm',
    );
    state = state.copyWith(isLoading: true, error: null);

    try {
      final lyrics = await provider.getLrc(searchTerm);
      if (lyrics == null) {
        debugPrint('No lyrics found from ${provider.name}');
        state = state.copyWith(
          isLoading: false,
          error: 'No lyrics found from ${provider.name}',
        );
        return;
      }

      // Parse the lyrics into LyricsData format
      String? lyricsJson;
      if (lyrics.synced != null) {
        // It's LRC format
        final lyricsData = LyricsParser.parseLrc(lyrics.synced!);
        lyricsJson = lyricsData.toJsonString();
      } else if (lyrics.plain != null) {
        // Plain text
        final lyricsData = LyricsParser.parsePlaintext(lyrics.plain!);
        lyricsJson = lyricsData.toJsonString();
      }

      if (lyricsJson != null) {
        // Update the track in the database
        final database = ref.read(databaseProvider);
        await (database.update(database.tracks)
              ..where((t) => t.id.equals(trackId)))
            .write(db.TracksCompanion(lyrics: drift.Value(lyricsJson)));

        debugPrint('Updated database with lyrics for track $trackId');

        // Update the current track provider if this is the current track
        final currentTrackNotifier = ref.read(currentTrackProvider.notifier);
        final currentTrack = currentTrackNotifier.state;
        if (currentTrack != null && currentTrack.id == trackId) {
          // Update the current track with new lyrics
          final updatedTrack = currentTrack.copyWith(lyrics: lyricsJson);
          currentTrackNotifier.setTrack(updatedTrack);
          debugPrint('Updated current track provider with new lyrics');
        }

        // Invalidate the track provider to refresh the UI.
        ref.invalidate(trackByPathProvider(trackPath));

        debugPrint('Invalidated track provider for $trackPath');

        state = state.copyWith(
          isLoading: false,
          successMessage: 'Lyrics fetched from ${provider.name}',
        );
      } else {
        debugPrint('Failed to parse lyrics');
        state = state.copyWith(
          isLoading: false,
          error: 'Failed to parse lyrics',
        );
      }
    } catch (e) {
      debugPrint('Error fetching lyrics: $e');
      state = state.copyWith(
        isLoading: false,
        error: 'Error fetching lyrics: $e',
      );
    }
  }
}

class LyricsFetcherState {
  final bool isLoading;
  final String? error;
  final String? successMessage;

  LyricsFetcherState({this.isLoading = false, this.error, this.successMessage});

  LyricsFetcherState copyWith({
    bool? isLoading,
    String? error,
    String? successMessage,
  }) {
    return LyricsFetcherState(
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      successMessage: successMessage ?? this.successMessage,
    );
  }
}

// Providers for each LRC provider
final musixmatchProvider = Provider((ref) => MusixmatchProvider());
final neteaseProvider = Provider((ref) => NetEaseProvider());
final lrclibProvider = Provider((ref) => LrclibProvider());
