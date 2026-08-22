import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:groovybox/data/db.dart';
import 'package:groovybox/logic/metadata_service.dart';
import 'package:groovybox/providers/audio_provider.dart';
import 'package:groovybox/providers/db_provider.dart';
import 'package:groovybox/providers/settings_provider.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:drift/drift.dart';

part 'track_repository.g.dart';

@riverpod
class TrackRepository extends _$TrackRepository {
  @override
  FutureOr<void> build() {}

  Stream<List<Track>> watchAllTracks() {
    final db = ref.watch(databaseProvider);
    return (db.select(
      db.tracks,
    )..orderBy([(t) => OrderingTerm(expression: t.title)])).watch();
  }

  Future<void> importFiles(List<String> filePaths) async {
    final db = ref.read(databaseProvider);
    final settings = ref.read(settingsProvider).value;
    final importMode = settings?.importMode ?? ImportMode.copy;

    // Filter out files that are already indexed
    final existingPaths = await (db.select(
      db.tracks,
    )..where((t) => t.path.isIn(filePaths))).map((t) => t.path).get();

    final existingPathsSet = existingPaths.toSet();
    final newFilePaths = filePaths
        .where((path) => !existingPathsSet.contains(path))
        .toList();

    if (newFilePaths.isEmpty) {
      return; // All files already indexed
    }

    if (importMode == ImportMode.copy) {
      await _importFilesWithCopy(newFilePaths);
    } else {
      await _importFilesInPlace(newFilePaths);
    }
  }

  Future<void> _importFilesWithCopy(List<String> filePaths) async {
    final db = ref.read(databaseProvider);
    final appDir = await getApplicationDocumentsDirectory();
    final musicDir = Directory(p.join(appDir.path, 'music'));

    await musicDir.create(recursive: true);

    final metadataService = MetadataService();

    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) continue;

      try {
        // 1. Copy file
        final filename = p.basename(path);
        // Ensure unique name to avoid overwriting or conflicts
        final uniqueName = '${DateTime.now().millisecondsSinceEpoch}_$filename';
        final newPath = p.join(musicDir.path, uniqueName);
        await file.copy(newPath);

        // 2. Extract Metadata
        final metadata = await metadataService.getMetadata(newPath);

        // 3. Insert into DB
        await db
            .into(db.tracks)
            .insert(
              TracksCompanion.insert(
                title: metadata.title ?? p.basenameWithoutExtension(filename),
                path: newPath, // Internal path
                artist: Value(metadata.artist),
                album: Value(metadata.album),
                duration: Value(metadata.durationMs), // Milliseconds
                artUri: Value(await _storeAlbumArt(metadata.artBytes)),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      } catch (e) {
        debugPrint('Error importing file $path: $e');
        // Continue to next file
      }
    }
  }

  /// Stores cover art bytes in the internal art directory and returns the
  /// resulting file path (or `null` when there is nothing to store).
  Future<String?> _storeAlbumArt(Uint8List? artBytes) async {
    if (artBytes == null || artBytes.isEmpty) return null;
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final artDir = Directory(p.join(appDir.path, 'art'));
      await artDir.create(recursive: true);
      final artFile = File(
        p.join(artDir.path, '${DateTime.now().millisecondsSinceEpoch}_art.jpg'),
      );
      await artFile.writeAsBytes(artBytes);
      return artFile.path;
    } catch (e) {
      debugPrint('Error storing album art: $e');
      return null;
    }
  }

  Future<void> _importFilesInPlace(List<String> filePaths) async {
    final metadataService = MetadataService();

    for (final path in filePaths) {
      final file = File(path);
      if (!await file.exists()) continue;

      try {
        // 1. Extract Metadata from original file
        final metadata = await metadataService.getMetadata(path);
        final filename = p.basename(path);

        // 2. Insert into DB with original path
        await _insertTrack(
          title: metadata.title ?? p.basenameWithoutExtension(filename),
          path: path, // Original path for in-place indexing
          artist: metadata.artist,
          album: metadata.album,
          durationMs: metadata.durationMs,
          artPath: await _storeAlbumArt(metadata.artBytes),
        );
      } catch (e) {
        debugPrint('Error importing file $path: $e');
        // Continue to next file
      }
    }
  }

  Future<void> _insertTrack({
    required String title,
    required String path,
    String? artist,
    String? album,
    int? durationMs,
    String? artPath,
  }) async {
    final db = ref.read(databaseProvider);
    await db
        .into(db.tracks)
        .insert(
          TracksCompanion.insert(
            title: title,
            path: path,
            artist: Value(artist),
            album: Value(album),
            duration: Value(durationMs), // Milliseconds
            artUri: Value(artPath),
          ),
          mode: InsertMode.insertOrIgnore,
        );
  }

  /// Re-reads tags for tracks that were imported with broken or missing
  /// metadata (e.g. empty titles caused by flutter_media_metadata's Windows
  /// non-ASCII path bug), so existing libraries heal without re-importing.
  Future<void> repairTracksWithMissingInfo() async {
    final db = ref.read(databaseProvider);

    final badTracks =
        await (db.select(db.tracks)..where(
              (t) =>
                  t.title.equals('') |
                  t.artist.equals('') |
                  t.duration.isNull(),
            ))
            .get();

    if (badTracks.isEmpty) return;
    debugPrint('Repairing metadata for ${badTracks.length} track(s)...');

    final metadataService = MetadataService();

    for (final track in badTracks) {
      try {
        final metadata = await metadataService.getMetadata(track.path);
        final needsTitle = track.title.trim().isEmpty;
        final needsArtist =
            track.artist == null || track.artist!.trim().isEmpty;
        final needsAlbum = track.album == null || track.album!.trim().isEmpty;

        await (db.update(db.tracks)..where((t) => t.id.equals(track.id))).write(
          TracksCompanion(
            title: needsTitle
                ? Value(
                    metadata.title ?? MetadataService.fallbackTitle(track.path),
                  )
                : const Value.absent(),
            artist: needsArtist ? Value(metadata.artist) : const Value.absent(),
            album: needsAlbum ? Value(metadata.album) : const Value.absent(),
            duration: track.duration == null
                ? Value(metadata.durationMs)
                : const Value.absent(),
            artUri: track.artUri == null && metadata.artBytes != null
                ? Value(await _storeAlbumArt(metadata.artBytes))
                : const Value.absent(),
          ),
        );
      } catch (e) {
        debugPrint('Error repairing metadata for ${track.path}: $e');
      }
    }
  }

  Future<void> updateMetadata({
    required int trackId,
    required String title,
    String? artist,
    String? album,
  }) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(
        title: Value(title),
        artist: Value(artist),
        album: Value(album),
      ),
    );
  }

  /// Replaces the cover art of [trackId] with a user-provided image.
  Future<void> updateTrackCover(int trackId, Uint8List imageBytes) async {
    final db = ref.read(databaseProvider);
    final track = await (db.select(
      db.tracks,
    )..where((t) => t.id.equals(trackId))).getSingleOrNull();
    if (track == null) return;

    final newPath = await _storeAlbumArt(imageBytes);
    if (newPath == null) return;

    await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(artUri: Value(newPath)),
    );

    // Remove the previous internal art file now that nothing references it.
    final oldArt = track.artUri;
    if (oldArt != null && oldArt != newPath && File(oldArt).existsSync()) {
      try {
        final appDir = await getApplicationDocumentsDirectory();
        // Only delete files inside our internal art directory.
        if (oldArt.startsWith(p.join(appDir.path, 'art'))) {
          await File(oldArt).delete();
        }
      } catch (e) {
        debugPrint('Error deleting old cover: $e');
      }
    }

    // Refresh the playing track's metadata so the mini player / player screen
    // pick up the new cover immediately.
    final currentTrack = ref.read(currentTrackProvider);
    if (currentTrack != null && currentTrack.id == trackId) {
      final notifier = ref.read(currentTrackMetadataProvider.notifier);
      final metadata = notifier.state;
      notifier.setMetadata(
        TrackMetadata(
          title: metadata?.title ?? currentTrack.title,
          artist: metadata?.artist ?? currentTrack.artist,
          album: metadata?.album ?? currentTrack.album,
          artBytes: imageBytes,
          durationMs: metadata?.durationMs,
        ),
      );
    }
  }

  Future<void> deleteTrack(int trackId) async {
    final db = ref.read(databaseProvider);

    // 1. Get track info to find file path
    final track = await (db.select(
      db.tracks,
    )..where((t) => t.id.equals(trackId))).getSingleOrNull();
    if (track == null) return;

    // 2. Delete from DB (cascade should handle playlist entries if configured, but we didn't set cascade on playlistEntries -> tracks properly maybe? CHECK DB)
    // In db.dart: IntColumn get trackId => integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
    // So DB deletion cascades to entries.

    await (db.delete(db.tracks)..where((t) => t.id.equals(trackId))).go();

    // 3. Delete file only if it's a copied file (in internal music directory)
    final appDir = await getApplicationDocumentsDirectory();
    final musicDir = p.join(appDir.path, 'music');

    final file = File(track.path);
    if (await file.exists()) {
      // Only delete if it's in our internal music directory (copied files)
      // For in-place indexed files, we don't delete the original
      if (track.path.startsWith(musicDir)) {
        try {
          await file.delete();
        } catch (e) {
          debugPrint("Error deleting file: $e");
        }
      }
    }

    // 4. Delete art if exists (album art is always stored internally)
    if (track.artUri != null) {
      final artFile = File(track.artUri!);
      if (await artFile.exists()) {
        try {
          await artFile.delete();
        } catch (e) {
          debugPrint("Error deleting art: $e");
        }
      }
    }
  }

  /// Update lyrics for a track.
  Future<void> updateLyrics(int trackId, String? lyricsJson) async {
    final db = ref.read(databaseProvider);
    await (db.update(db.tracks)..where((t) => t.id.equals(trackId))).write(
      TracksCompanion(lyrics: Value(lyricsJson)),
    );

    // Update current track provider if this is the current track
    final currentTrackNotifier = ref.read(currentTrackProvider.notifier);
    final currentTrack = currentTrackNotifier.state;
    if (currentTrack != null && currentTrack.id == trackId) {
      final updatedTrack = currentTrack.copyWith(lyrics: lyricsJson);
      currentTrackNotifier.setTrack(updatedTrack);
      debugPrint('Updated current track provider with imported lyrics');
    }
  }

  /// Get a single track by ID.
  Future<Track?> getTrack(int trackId) async {
    final db = ref.read(databaseProvider);
    return (db.select(
      db.tracks,
    )..where((t) => t.id.equals(trackId))).getSingleOrNull();
  }

  /// Get all tracks for batch matching.
  Future<List<Track>> getAllTracks() async {
    final db = ref.read(databaseProvider);
    return db.select(db.tracks).get();
  }

  /// Scan a directory for music files and import them.
  Future<void> scanDirectory(
    String directoryPath, {
    bool recursive = true,
  }) async {
    final settings = ref.read(settingsProvider).value;
    final supportedFormats =
        settings?.supportedFormats ??
        {'.mp3', '.flac', '.wav', '.m4a', '.aac', '.ogg', '.wma', '.opus'};

    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      throw Exception('Directory does not exist: $directoryPath');
    }

    final List<String> musicFiles = [];

    await for (final entity in directory.list(recursive: recursive)) {
      if (entity is File) {
        final extension = p.extension(entity.path).toLowerCase();
        if (supportedFormats.contains(extension)) {
          musicFiles.add(entity.path);
        }
      }
    }

    if (musicFiles.isNotEmpty) {
      await importFiles(musicFiles);
    }
  }

  /// Scan all watch folders for new/updated files.
  Future<void> scanWatchFolders() async {
    final db = ref.read(databaseProvider);
    final watchFolders = await (db.select(
      db.watchFolders,
    )..where((t) => t.isActive.equals(true))).get();

    for (final folder in watchFolders) {
      try {
        await scanDirectory(folder.path, recursive: folder.recursive);

        // Update last scanned time
        await (db.update(db.watchFolders)..where((t) => t.id.equals(folder.id)))
            .write(WatchFoldersCompanion(lastScanned: Value(DateTime.now())));
      } catch (e) {
        debugPrint('Error scanning watch folder ${folder.path}: $e');
      }
    }
  }

  /// Add a file from watch folder event.
  Future<void> addFileFromWatch(String filePath) async {
    final settings = ref.read(settingsProvider).value;
    final supportedFormats =
        settings?.supportedFormats ??
        {'.mp3', '.flac', '.wav', '.m4a', '.aac', '.ogg', '.wma', '.opus'};

    final extension = p.extension(filePath).toLowerCase();
    if (!supportedFormats.contains(extension)) {
      return; // Not a supported audio file
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return;
    }

    await importFiles([filePath]);
  }

  /// Remove a file from watch folder event.
  Future<void> removeFileFromWatch(String filePath) async {
    final db = ref.read(databaseProvider);

    // Find track by path
    final track = await (db.select(
      db.tracks,
    )..where((t) => t.path.equals(filePath))).getSingleOrNull();

    if (track != null) {
      await deleteTrack(track.id);
    }
  }

  /// Update a file from watch folder event.
  Future<void> updateFileFromWatch(String filePath) async {
    // For now, we remove and re-add the file
    // In a more sophisticated implementation, we could update metadata only
    await removeFileFromWatch(filePath);
    await addFileFromWatch(filePath);
  }

  /// Check if a track exists and is accessible.
  Future<bool> isTrackAccessible(String filePath) async {
    try {
      final file = File(filePath);
      return await file.exists();
    } catch (e) {
      debugPrint('Error checking track accessibility $filePath: $e');
      return false;
    }
  }

  /// Clean up tracks that no longer exist (for in-place indexed tracks).
  Future<void> cleanupMissingTracks() async {
    final db = ref.read(databaseProvider);
    final settings = ref.read(settingsProvider).value;

    if (settings?.importMode == ImportMode.copy) {
      return; // Only cleanup for in-place indexed tracks
    }

    final allTracks = await db.select(db.tracks).get();

    for (final track in allTracks) {
      if (!await isTrackAccessible(track.path)) {
        debugPrint('Removing missing track: ${track.path}');
        // Remove from database but don't delete file (since it doesn't exist)
        await (db.delete(db.tracks)..where((t) => t.id.equals(track.id))).go();

        // Clean up album art
        if (track.artUri != null) {
          final artFile = File(track.artUri!);
          if (await artFile.exists()) {
            try {
              await artFile.delete();
            } catch (e) {
              debugPrint("Error deleting missing track's art: $e");
            }
          }
        }
      }
    }
  }

  /// Clear all tracks from the database and delete associated files/art.
  Future<void> clearAllTracks() async {
    final db = ref.read(databaseProvider);
    final appDir = await getApplicationDocumentsDirectory();
    final musicDir = p.join(appDir.path, 'music');

    // Get all tracks first
    final allTracks = await db.select(db.tracks).get();

    // Delete associated files and art for each track
    for (final track in allTracks) {
      // Delete file only if it's a copied file (in internal music directory)
      final file = File(track.path);
      if (await file.exists() && track.path.startsWith(musicDir)) {
        try {
          await file.delete();
        } catch (e) {
          debugPrint("Error deleting file: $e");
        }
      }

      // Delete album art if exists (always stored internally)
      if (track.artUri != null) {
        final artFile = File(track.artUri!);
        if (await artFile.exists()) {
          try {
            await artFile.delete();
          } catch (e) {
            debugPrint("Error deleting art: $e");
          }
        }
      }
    }

    // Clear all tracks from database (cascade will handle playlist entries)
    await db.delete(db.tracks).go();
  }
}
