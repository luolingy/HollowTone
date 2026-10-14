import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hollowtone/data/db.dart';
import 'package:hollowtone/data/track_repository.dart';
import 'package:hollowtone/providers/db_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:drift/drift.dart';

// Simple watch folder provider using Riverpod
final watchFoldersProvider = FutureProvider<List<WatchFolder>>((ref) async {
  final db = ref.read(databaseProvider);
  return await (db.select(
    db.watchFolders,
  )..orderBy([(t) => OrderingTerm(expression: t.addedAt)])).get();
});

final activeWatchFoldersProvider = Provider<List<WatchFolder>>((ref) {
  final watchFoldersAsync = ref.watch(watchFoldersProvider);
  return watchFoldersAsync.when(
    data: (folders) => folders.where((folder) => folder.isActive).toList(),
    loading: () => [],
    error: (_, _) => [],
  );
});

class WatchFolderService {
  final Ref ref;

  WatchFolderService(this.ref);

  Future<void> addWatchFolder(
    String path, {
    String? name,
    bool recursive = true,
  }) async {
    final db = ref.read(databaseProvider);
    final directory = Directory(path);

    if (!await directory.exists()) {
      throw Exception('Directory does not exist: $path');
    }

    final folderName = name ?? p.basename(path);

    await db
        .into(db.watchFolders)
        .insert(
          WatchFoldersCompanion.insert(
            path: path,
            name: folderName,
            recursive: Value(recursive),
          ),
        );

    // Invalidate the provider to refresh UI
    ref.invalidate(watchFoldersProvider);
  }

  Future<void> removeWatchFolder(int folderId) async {
    final db = ref.read(databaseProvider);

    await (db.delete(
      db.watchFolders,
    )..where((t) => t.id.equals(folderId))).go();

    // Invalidate the provider to refresh UI
    ref.invalidate(watchFoldersProvider);
  }

  Future<void> toggleWatchFolder(int folderId, bool isActive) async {
    final db = ref.read(databaseProvider);

    await (db.update(db.watchFolders)..where((t) => t.id.equals(folderId)))
        .write(WatchFoldersCompanion(isActive: Value(isActive)));

    // Invalidate the provider to refresh UI
    ref.invalidate(watchFoldersProvider);
  }

  Future<void> updateLastScanned(int folderId) async {
    final db = ref.read(databaseProvider);

    await (db.update(db.watchFolders)..where((t) => t.id.equals(folderId)))
        .write(WatchFoldersCompanion(lastScanned: Value(DateTime.now())));

    // Invalidate the provider to refresh UI
    ref.invalidate(watchFoldersProvider);
  }

  Future<void> scanWatchFolders() async {
    final trackRepository = ref.read(trackRepositoryProvider.notifier);
    await trackRepository.scanWatchFolders();
  }

  Future<void> cleanupMissingTracks() async {
    // Remove tracks that no longer exist
    final db = ref.read(databaseProvider);
    final allTracks = await db.select(db.tracks).get();

    for (final track in allTracks) {
      final file = File(track.path);
      if (!await file.exists()) {
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
}

// Provider for the service
final watchFolderServiceProvider = Provider<WatchFolderService>((ref) {
  return WatchFolderService(ref);
});
