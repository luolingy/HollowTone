import 'package:hollowtone/logic/audio_handler.dart';
import 'package:hollowtone/logic/metadata_service.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:hollowtone/data/db.dart' as db;

part 'audio_provider.g.dart';

// Simple data class for current track to avoid drift type issues
class CurrentTrackData {
  final int id;
  final String title;
  final String? artist;
  final String? album;
  final String path;
  final String? lyrics;
  final int lyricsOffset;

  CurrentTrackData({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    required this.path,
    this.lyrics,
    required this.lyricsOffset,
  });

  factory CurrentTrackData.fromTrack(db.Track track) {
    return CurrentTrackData(
      id: track.id,
      title: track.title,
      artist: track.artist,
      album: track.album,
      path: track.path,
      lyrics: track.lyrics,
      lyricsOffset: track.lyricsOffset,
    );
  }

  CurrentTrackData copyWith({
    int? id,
    String? title,
    String? artist,
    String? album,
    String? path,
    String? lyrics,
    int? lyricsOffset,
  }) {
    return CurrentTrackData(
      id: id ?? this.id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      path: path ?? this.path,
      lyrics: lyrics ?? this.lyrics,
      lyricsOffset: lyricsOffset ?? this.lyricsOffset,
    );
  }
}

// This should be set after AudioService.init in main.dart
late AudioHandler _audioHandler;

@Riverpod(keepAlive: true)
AudioHandler audioHandler(Ref ref) {
  return _audioHandler;
}

// Function to set the audio handler after initialization
void setAudioHandler(AudioHandler handler) {
  _audioHandler = handler;
}

@Riverpod(keepAlive: true)
class CurrentTrackNotifier extends _$CurrentTrackNotifier {
  @override
  CurrentTrackData? build() {
    return null;
  }

  void setTrack(CurrentTrackData? track) {
    state = track;
  }

  void clear() {
    state = null;
  }
}

@Riverpod(keepAlive: true)
class CurrentTrackMetadataNotifier extends _$CurrentTrackMetadataNotifier {
  @override
  TrackMetadata? build() {
    return null;
  }

  void setMetadata(TrackMetadata metadata) {
    state = metadata;
  }

  void clear() {
    state = null;
  }
}

@Riverpod(keepAlive: true)
class RemoteTrackLoadingNotifier extends _$RemoteTrackLoadingNotifier {
  @override
  bool build() {
    return false;
  }

  void setLoading(bool loading) {
    state = loading;
  }
}
