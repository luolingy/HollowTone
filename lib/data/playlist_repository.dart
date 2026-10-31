import 'package:drift/drift.dart';
import 'package:hollowtone/logic/cloud_api.dart';
import 'package:hollowtone/logic/sync_service.dart';
import 'package:hollowtone/providers/cloud_sync_provider.dart';
import 'package:hollowtone/providers/db_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'db.dart';

part 'playlist_repository.g.dart';

@riverpod
class PlaylistRepository extends _$PlaylistRepository {
  @override
  FutureOr<void> build() {}

  /// Marks a playlist as needing a cloud-sync push (no-op when unconfigured).
  Future<void> _markCloudDirty(int playlistId) async {
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.isConfigured) return;
      final api = HollowToneApi(baseUrl: cloud.serverUrl, token: cloud.token);
      await SyncService(
        db: ref.read(databaseProvider),
        api: api,
      ).markPlaylistDirty(playlistId);
    } catch (_) {
      // Local edits must never break on sync bookkeeping.
    }
  }

  /// Pushes a cloud tombstone for [playlistId] before it is deleted locally.
  Future<void> _pushCloudDelete(int playlistId) async {
    try {
      final cloud = ref.read(cloudSyncProvider);
      if (!cloud.isConfigured) return;
      final api = HollowToneApi(baseUrl: cloud.serverUrl, token: cloud.token);
      await SyncService(
        db: ref.read(databaseProvider),
        api: api,
      ).pushPlaylistDelete(playlistId);
    } catch (_) {
      // Ignore; deletion should still proceed locally.
    }
  }

  // --- Playlists ---

  Stream<List<Playlist>> watchAllPlaylists() {
    final db = ref.watch(databaseProvider);
    return (db.select(
      db.playlists,
    )..orderBy([(p) => OrderingTerm(expression: p.createdAt)])).watch();
  }

  Stream<List<Track>> watchPlaylistTracks(int playlistId) {
    final db = ref.watch(databaseProvider);
    // Join PlaylistsEntries with Tracks, honoring the persisted custom order.
    final query =
        db.select(db.playlistEntries).join([
            innerJoin(
              db.tracks,
              db.tracks.id.equalsExp(db.playlistEntries.trackId),
            ),
          ])
          ..where(db.playlistEntries.playlistId.equals(playlistId))
          ..orderBy([
            OrderingTerm(expression: db.playlistEntries.position),
            OrderingTerm(expression: db.playlistEntries.addedAt),
          ]);

    return query.map((row) => row.readTable(db.tracks)).watch();
  }

  Future<int> createPlaylist(String name) async {
    final db = ref.read(databaseProvider);
    final id =
        await db.into(db.playlists).insert(PlaylistsCompanion.insert(name: name));
    await _markCloudDirty(id);
    return id;
  }

  Future<void> addToPlaylist(int playlistId, int trackId) async {
    final db = ref.read(databaseProvider);

    // Append at the end of the custom order.
    final maxExp = db.playlistEntries.position.max();
    final row =
        await (db.selectOnly(db.playlistEntries)
              ..addColumns([maxExp])
              ..where(db.playlistEntries.playlistId.equals(playlistId)))
            .getSingleOrNull();
    final nextPos = (row?.read(maxExp) ?? -1) + 1;

    await db
        .into(db.playlistEntries)
        .insert(
          PlaylistEntriesCompanion.insert(
            playlistId: playlistId,
            trackId: trackId,
            position: Value(nextPos),
          ),
          mode: InsertMode.insertOrIgnore, // Prevent dupes if needed, or allow
        );
    await _markCloudDirty(playlistId);
  }

  /// Persists a custom track order for [playlistId].
  Future<void> reorderPlaylistTracks(
    int playlistId,
    List<int> orderedTrackIds,
  ) async {
    final db = ref.read(databaseProvider);
    await db.transaction(() async {
      for (final entry in orderedTrackIds.indexed) {
        await (db.update(db.playlistEntries)..where(
              (e) =>
                  e.playlistId.equals(playlistId) &
                  e.trackId.equals(entry.$2),
            ))
            .write(PlaylistEntriesCompanion(position: Value(entry.$1)));
      }
    });
    await _markCloudDirty(playlistId);
  }

  Future<void> deletePlaylist(int playlistId) async {
    final db = ref.read(databaseProvider);
    await _pushCloudDelete(playlistId);
    // entries cascade delete
    await (db.delete(db.playlists)..where((p) => p.id.equals(playlistId))).go();
  }

  Future<void> removeFromPlaylist(int playlistId, int trackId) async {
    final db = ref.read(databaseProvider);
    await (db.delete(db.playlistEntries)..where(
          (e) => e.playlistId.equals(playlistId) & e.trackId.equals(trackId),
        ))
        .go();
    await _markCloudDirty(playlistId);
  }

  // --- Albums ---

  Stream<List<AlbumData>> watchAllAlbums() {
    final db = ref.watch(databaseProvider);
    // Distinct albums by grouping - group by album name only to prevent duplicates
    // when the same album has inconsistent artist metadata across tracks
    final query = db.selectOnly(db.tracks)
      ..addColumns([
        db.tracks.album,
        db.tracks.artist.min(), // Get the first non-null artist
        db.tracks.artUri.min(), // Get the first non-null art URI
      ])
      ..where(db.tracks.album.isNotNull())
      ..groupBy([db.tracks.album]);

    return query.map((row) {
      return AlbumData(
        album: row.read(db.tracks.album)!,
        artist: row.read(db.tracks.artist.min()) ?? 'Various Artists',
        artUri: row.read(db.tracks.artUri.min()),
      );
    }).watch();
  }

  Stream<List<Track>> watchAlbumTracks(String albumName) {
    final db = ref.watch(databaseProvider);
    return (db.select(
      db.tracks,
    )..where((t) => t.album.equals(albumName))).watch();
  }
}

class AlbumData {
  final String album;
  final String artist;
  final String? artUri;

  AlbumData({required this.album, required this.artist, this.artUri});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlbumData && album == other.album && artist == other.artist;

  @override
  int get hashCode => Object.hash(album, artist);
}
