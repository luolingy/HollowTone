import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:hollowtone/providers/db_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:audio_metadata_reader/audio_metadata_reader.dart' as amr;
import 'package:flutter_media_metadata/flutter_media_metadata.dart' as fmm;

class TrackMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final Uint8List? artBytes;
  final int? durationMs;

  TrackMetadata({
    this.title,
    this.artist,
    this.album,
    this.artBytes,
    this.durationMs,
  });
}

class MetadataService {
  /// Reads tags from the file at [path].
  ///
  /// The pure-Dart [amr] parser is tried first: it handles non-ASCII (e.g.
  /// Chinese) file paths correctly on every platform. The native
  /// [fmm.MetadataRetriever] is only used as a fallback for formats the Dart
  /// parser cannot handle (e.g. WMA) - its Windows implementation mangles
  /// non-ASCII paths and reports empty strings instead of nulls, so results
  /// are normalized through [clean].
  Future<TrackMetadata> getMetadata(String path) async {
    final fallbackTitle = MetadataService.fallbackTitle(path);
    final file = File(path);
    if (!await file.exists()) {
      return TrackMetadata(title: fallbackTitle);
    }

    try {
      // The pure-Dart parser is CPU-bound; run it on a background isolate so
      // large imports / library scans never block the UI thread.
      final metadata = await Isolate.run(() {
        return amr.readMetadata(File(path), getImage: true);
      });
      String? artist = MetadataService.clean(metadata.artist);
      if (artist == null && metadata.performers.isNotEmpty) {
        artist = MetadataService.clean(metadata.performers.join(', '));
      }
      Uint8List? artBytes;
      if (metadata.pictures.isNotEmpty) {
        artBytes = metadata.pictures.first.bytes;
      }
      return TrackMetadata(
        title: MetadataService.clean(metadata.title),
        artist: artist,
        album: MetadataService.clean(metadata.album),
        artBytes: artBytes,
        durationMs: metadata.duration?.inMilliseconds,
      );
    } catch (_) {
      // Pure-Dart parser does not support this format; fall through to the
      // native reader below.
    }

    try {
      final metadata = await fmm.MetadataRetriever.fromFile(file);
      return TrackMetadata(
        title: MetadataService.clean(metadata.trackName),
        artist: MetadataService.clean(metadata.trackArtistNames?.join(', ')),
        album: MetadataService.clean(metadata.albumName),
        artBytes: metadata.albumArt,
        durationMs: metadata.trackDuration,
      );
    } catch (_) {
      // Ignore - fall back to file name based metadata below.
    }

    return TrackMetadata(title: fallbackTitle);
  }

  /// Returns [value] with surrounding whitespace removed, or `null` when it
  /// is empty. Native tag readers often report missing tags as `''` instead
  /// of `null`, which would otherwise defeat `??`-style fallbacks.
  static String? clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed;
  }

  /// Best-effort display title derived from the file name.
  static String fallbackTitle(String path) => p.basenameWithoutExtension(path);
}

final trackMetadataProvider = FutureProvider.family<TrackMetadata, String>((
  ref,
  path,
) async {
  try {
    final db = ref.watch(databaseProvider);

    final track = await (db.select(
      db.tracks,
    )..where((t) => t.path.equals(path))).getSingleOrNull();

    if (track != null) {
      // For remote tracks, try to fetch album art from the stored URL
      Uint8List? artBytes;
      if (track.artUri != null && _isNetworkUri(track.artUri!)) {
        try {
          final response = await http.get(Uri.parse(track.artUri!));
          if (response.statusCode == 200) {
            artBytes = response.bodyBytes;
          }
        } catch (e) {
          debugPrint('Failed to fetch album art from ${track.artUri}: $e');
        }
      }

      return TrackMetadata(
        title:
            MetadataService.clean(track.title) ??
            MetadataService.fallbackTitle(track.path),
        artist: MetadataService.clean(track.artist),
        album: MetadataService.clean(track.album),
        artBytes: artBytes,
        durationMs: track.duration,
      );
    } else {
      return TrackMetadata(title: MetadataService.fallbackTitle(path));
    }
  } catch (e) {
    debugPrint('Error fetching metadata for $path: $e');
    return TrackMetadata();
  }
});

bool _isNetworkUri(String uri) =>
    uri.startsWith('http://') || uri.startsWith('https://');
