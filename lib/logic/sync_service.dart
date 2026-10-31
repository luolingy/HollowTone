// HollowTone cloud synchronization engine.
//
// Bridges the local drift database with the personal server:
//
//  * Maintains a `sync_map` table (created here with raw SQL, so no
//    build_runner regeneration is required) mapping local integer ids to
//    server GUIDs plus the last-seen server version.
//  * Push: every locally modified track/playlist is uploaded with its
//    baseVersion. On 409 the server wins; the local row adopts the server's
//    authoritative copy.
//  * Pull: `GET /sync?since=<watermark>` returns changes since the last pull;
//    new remote rows are inserted locally, existing ones updated, and
//    tombstones delete the local row.
//  * Bootstrap: local tracks/playlists that predate sync get a stable GUID on
//    first run and are pushed.
//
// All persistence goes through AppDatabase.customSelect / customStatement,
// keeping the generated drift code untouched.
library;

import 'package:drift/drift.dart';
import 'package:hollowtone/data/db.dart';
import 'package:hollowtone/logic/cloud_api.dart';

/// A row of the sync_map table.
class SyncMapEntry {
  final String entity; // 'track' | 'playlist'
  final int localId;
  final String guid;
  final int version;
  final int updatedAt; // server-side updated_at (ms)
  final bool dirty;
  SyncMapEntry({
    required this.entity,
    required this.localId,
    required this.guid,
    required this.version,
    required this.updatedAt,
    required this.dirty,
  });
}

/// Outcome summary of one sync pass.
class SyncReport {
  int pushedTracks = 0;
  int pulledTracks = 0;
  int deletedTracks = 0;
  int pushedPlaylists = 0;
  int pulledPlaylists = 0;
  int conflicts = 0;
  int serverTime = 0;
  String? error;

  bool get hasError => error != null;

  @override
  String toString() =>
      'SyncReport(pushed=$pushedTracks/$pushedPlaylists, '
      'pulled=$pulledTracks/$pulledPlaylists, deleted=$deletedTracks, '
      'conflicts=$conflicts${error != null ? ", error=$error" : ""})';
}

/// Performs push+pull synchronization for one user against one server.
class SyncService {
  final AppDatabase db;
  final HollowToneApi api;

  SyncService({required this.db, required this.api});

  static const _table = 'sync_map';

  /// Creates the sync_map table if absent. Safe to call repeatedly.
  Future<void> ensureInitialized() async {
    await db.customStatement('''
      CREATE TABLE IF NOT EXISTS $_table (
        entity     TEXT    NOT NULL,
        local_id   INTEGER NOT NULL,
        guid       TEXT    NOT NULL,
        version    INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        dirty      INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY (entity, local_id)
      )
    ''');
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sync_map_guid ON $_table(entity, guid)',
    );
  }

  // --- map helpers ----------------------------------------------------------

  Future<SyncMapEntry?> _mapFor(String entity, int localId) async {
    final rows = await db.customSelect(
      'SELECT entity, local_id, guid, version, updated_at, dirty FROM $_table '
      'WHERE entity = ? AND local_id = ?',
      variables: [Variable.withString(entity), Variable.withInt(localId)],
    ).get();
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  Future<SyncMapEntry?> _mapForGuid(String entity, String guid) async {
    final rows = await db.customSelect(
      'SELECT entity, local_id, guid, version, updated_at, dirty FROM $_table '
      'WHERE entity = ? AND guid = ?',
      variables: [Variable.withString(entity), Variable.withString(guid)],
    ).get();
    if (rows.isEmpty) return null;
    return _rowToMap(rows.first);
  }

  SyncMapEntry _rowToMap(QueryRow r) => SyncMapEntry(
        entity: r.read<String>('entity'),
        localId: r.read<int>('local_id'),
        guid: r.read<String>('guid'),
        version: r.read<int>('version'),
        updatedAt: r.read<int>('updated_at'),
        dirty: r.read<int>('dirty') != 0,
      );

  Future<void> _upsertMap(SyncMapEntry e) async {
    await db.customStatement(
      'INSERT INTO $_table(entity, local_id, guid, version, updated_at, dirty) '
      'VALUES(?,?,?,?,?,?) '
      'ON CONFLICT(entity, local_id) DO UPDATE SET '
      'guid=excluded.guid, version=excluded.version, '
      'updated_at=excluded.updated_at, dirty=excluded.dirty',
      [
        e.entity,
        e.localId,
        e.guid,
        e.version,
        e.updatedAt,
        e.dirty ? 1 : 0,
      ],
    );
  }

  Future<List<SyncMapEntry>> _allMaps(String entity) async {
    final rows = await db.customSelect(
      'SELECT entity, local_id, guid, version, updated_at, dirty FROM $_table '
      'WHERE entity = ?',
      variables: [Variable.withString(entity)],
    ).get();
    return rows.map(_rowToMap).toList();
  }

  /// Generates a client-side stable GUID for a new entity.
  static String newGuid(String prefix) {
    final now = DateTime.now().microsecondsSinceEpoch;
    final rand = DateTime.now().hashCode & 0xffff;
    return '$prefix-$now-$rand';
  }

  /// Marks a local track dirty so the next push uploads it. Call this whenever
  /// a track row is edited locally (metadata, lyrics, etc.).
  Future<void> markTrackDirty(int localId) async {
    final existing = await _mapFor('track', localId);
    if (existing == null) {
      // Assign a GUID on first touch so the entity can be pushed.
      await _upsertMap(SyncMapEntry(
        entity: 'track',
        localId: localId,
        guid: newGuid('track'),
        version: 0,
        updatedAt: 0,
        dirty: true,
      ));
    } else {
      await db.customStatement(
        'UPDATE $_table SET dirty = 1 WHERE entity = ? AND local_id = ?',
        ['track', localId],
      );
    }
  }

  /// Marks a local playlist dirty so the next push uploads it.
  Future<void> markPlaylistDirty(int localId) async {
    final existing = await _mapFor('playlist', localId);
    if (existing == null) {
      await _upsertMap(SyncMapEntry(
        entity: 'playlist',
        localId: localId,
        guid: newGuid('playlist'),
        version: 0,
        updatedAt: 0,
        dirty: true,
      ));
    } else {
      await db.customStatement(
        'UPDATE $_table SET dirty = 1 WHERE entity = ? AND local_id = ?',
        ['playlist', localId],
      );
    }
  }

  // --- bootstrap ------------------------------------------------------------

  /// Ensures every existing local track/playlist has a sync mapping so that
  /// pre-existing libraries get uploaded on first sync. Does not push by
  /// itself; it just marks unmapped rows as new (version 0, dirty).
  Future<void> bootstrapExistingRows() async {
    final tracks = await db.select(db.tracks).get();
    for (final t in tracks) {
      final m = await _mapFor('track', t.id);
      if (m == null) {
        await _upsertMap(SyncMapEntry(
          entity: 'track',
          localId: t.id,
          guid: newGuid('track'),
          version: 0,
          updatedAt: 0,
          dirty: true,
        ));
      }
    }
    final playlists = await db.select(db.playlists).get();
    for (final p in playlists) {
      final m = await _mapFor('playlist', p.id);
      if (m == null) {
        await _upsertMap(SyncMapEntry(
          entity: 'playlist',
          localId: p.id,
          guid: newGuid('playlist'),
          version: 0,
          updatedAt: 0,
          dirty: true,
        ));
      }
    }
  }

  // --- push -----------------------------------------------------------------

  /// Pushes all dirty tracks, then dirty playlists. Returns counts in [report].
  Future<void> push(SyncReport report) async {
    await _pushTracks(report);
    await _pushPlaylists(report);
  }

  Future<void> _pushTracks(SyncReport report) async {
    final maps = await _allMaps('track');
    for (final m in maps) {
      if (!m.dirty) continue;
      final t = await (db.select(db.tracks)
            ..where((x) => x.id.equals(m.localId)))
          .getSingleOrNull();
      if (t == null) continue;

      final body = <String, dynamic>{
        'title': t.title,
        'artist': t.artist,
        'album': t.album,
        'durationMs': t.duration,
        'lyrics': t.lyrics,
        'lyricsOffsetMs': t.lyricsOffset,
        'baseVersion': m.version,
      };
      try {
        final res = await api.upsertTrack(m.guid, body);
        await _upsertMap(m.copyWith(
          version: (res['version'] as num?)?.toInt() ?? m.version + 1,
          updatedAt: (res['updatedAt'] as num?)?.toInt() ?? _nowMs(),
          dirty: false,
        ));
        report.pushedTracks++;
      } on SyncConflict catch (c) {
        report.conflicts++;
        // Server wins: adopt its authoritative version, clear dirty, then apply
        // its metadata locally so the two sides converge.
        await _adoptServerTrack(m, c.current);
      }
    }
  }

  Future<void> _pushPlaylists(SyncReport report) async {
    final maps = await _allMaps('playlist');
    for (final m in maps) {
      if (!m.dirty) continue;
      final p = await (db.select(db.playlists)
            ..where((x) => x.id.equals(m.localId)))
          .getSingleOrNull();
      if (p == null) continue;

      final entries = await _localPlaylistEntries(p.id);
      final body = <String, dynamic>{
        'name': p.name,
        'entries': entries,
        'baseVersion': m.version,
      };
      try {
        final res = await api.upsertPlaylist(m.guid, body);
        await _upsertMap(m.copyWith(
          version: (res['version'] as num?)?.toInt() ?? m.version + 1,
          updatedAt: (res['updatedAt'] as num?)?.toInt() ?? _nowMs(),
          dirty: false,
        ));
        report.pushedPlaylists++;
      } on SyncConflict catch (c) {
        report.conflicts++;
        await _adoptServerPlaylist(m, c.current);
      }
    }
  }

  /// Serialises a local playlist's entries as the server expects:
  /// a list of `{trackGuid, position}`. Requires each track to have a mapping.
  Future<List<Map<String, dynamic>>> _localPlaylistEntries(
    int playlistId,
  ) async {
    final rows = await (db.select(db.playlistEntries)
          ..where((e) => e.playlistId.equals(playlistId))
          ..orderBy([(e) => OrderingTerm(expression: e.position)]))
        .get();
    final out = <Map<String, dynamic>>[];
    var pos = 0;
    for (final e in rows) {
      final m = await _mapFor('track', e.trackId);
      if (m == null) continue; // skip unmapped (will map on its own push)
      out.add({'trackGuid': m.guid, 'position': pos++});
    }
    return out;
  }

  // --- pull -----------------------------------------------------------------

  /// Pulls changes since [sinceMillis] and applies them locally.
  /// Returns the new watermark in [report.serverTime].
  Future<void> pull(SyncReport report, int sinceMillis) async {
    final result = await api.sync(sinceMillis: sinceMillis);
    report.serverTime = result.serverTime;

    for (final remote in result.tracks) {
      await _applyRemoteTrack(remote, report);
    }
    for (final remote in result.playlists) {
      await _applyRemotePlaylist(remote, report);
    }
  }

  Future<void> _applyRemoteTrack(
    Map<String, dynamic> r,
    SyncReport report,
  ) async {
    final guid = r['guid'] as String;
    final version = (r['version'] as num?)?.toInt() ?? 0;
    final updatedAt = (r['updatedAt'] as num?)?.toInt() ?? 0;
    final deleted = (r['deleted'] as bool?) ?? false;
    final map = await _mapForGuid('track', guid);

    if (deleted) {
      if (map != null) {
        await (db.delete(db.tracks)..where((t) => t.id.equals(map.localId))).go();
        await db.customStatement(
          'DELETE FROM $_table WHERE entity = ? AND local_id = ?',
          ['track', map.localId],
        );
        report.deletedTracks++;
      }
      return;
    }

    if (map != null) {
      // Update the existing local row from the server copy (server wins on pull).
      await (db.update(db.tracks)..where((t) => t.id.equals(map.localId))).write(
        TracksCompanion(
          title: Value(r['title'] as String? ?? ''),
          artist: Value(r['artist'] as String?),
          album: Value(r['album'] as String?),
          duration: Value((r['durationMs'] as num?)?.toInt()),
          lyrics: Value(r['lyrics'] as String?),
          lyricsOffset: Value((r['lyricsOffsetMs'] as num?)?.toInt() ?? 0),
        ),
      );
      await _upsertMap(map.copyWith(
        version: version,
        updatedAt: updatedAt,
        dirty: false,
      ));
      report.pulledTracks++;
    } else {
      // Insert a new remote-origin track. The path is a cloud sentinel; the
      // player resolves `hollowtone://cloud/<guid>` to a stream URL at play
      // time (see cloud source handling). Store the guid in the path so it is
      // recoverable without an extra map lookup.
      final newId = await db.into(db.tracks).insert(
            TracksCompanion.insert(
              title: r['title'] as String? ?? 'Unknown',
              path: 'hollowtone://cloud/$guid',
              artist: Value(r['artist'] as String?),
              album: Value(r['album'] as String?),
              duration: Value((r['durationMs'] as num?)?.toInt()),
              lyrics: Value(r['lyrics'] as String?),
              lyricsOffset:
                  Value((r['lyricsOffsetMs'] as num?)?.toInt() ?? 0),
            ),
          );
      await _upsertMap(SyncMapEntry(
        entity: 'track',
        localId: newId,
        guid: guid,
        version: version,
        updatedAt: updatedAt,
        dirty: false,
      ));
      report.pulledTracks++;
    }
  }

  Future<void> _applyRemotePlaylist(
    Map<String, dynamic> r,
    SyncReport report,
  ) async {
    final guid = r['guid'] as String;
    final version = (r['version'] as num?)?.toInt() ?? 0;
    final updatedAt = (r['updatedAt'] as num?)?.toInt() ?? 0;
    final deleted = (r['deleted'] as bool?) ?? false;
    final map = await _mapForGuid('playlist', guid);

    if (deleted) {
      if (map != null) {
        await (db.delete(db.playlists)
              ..where((p) => p.id.equals(map.localId)))
            .go();
        await db.customStatement(
          'DELETE FROM $_table WHERE entity = ? AND local_id = ?',
          ['playlist', map.localId],
        );
      }
      return;
    }

    int localId;
    if (map != null) {
      localId = map.localId;
      await (db.update(db.playlists)
            ..where((p) => p.id.equals(localId)))
          .write(PlaylistsCompanion(name: Value(r['name'] as String? ?? '')));
      report.pulledPlaylists++;
    } else {
      localId = await db.into(db.playlists).insert(
            PlaylistsCompanion.insert(name: r['name'] as String? ?? 'Playlist'),
          );
      report.pulledPlaylists++;
    }

    // Rebuild entries from the server's ordered list.
    await (db.delete(db.playlistEntries)
          ..where((e) => e.playlistId.equals(localId)))
        .go();
    final entries = (r['entries'] as List?) ?? [];
    var pos = 0;
    for (final e in entries) {
      final trackGuid = (e as Map)['trackGuid'] as String?;
      if (trackGuid == null) continue;
      final tm = await _mapForGuid('track', trackGuid);
      if (tm == null) continue; // track not yet pulled; skip for now
      await db.into(db.playlistEntries).insert(
            PlaylistEntriesCompanion.insert(
              playlistId: localId,
              trackId: tm.localId,
              position: Value(pos++),
            ),
          );
    }

    await _upsertMap(SyncMapEntry(
      entity: 'playlist',
      localId: localId,
      guid: guid,
      version: version,
      updatedAt: updatedAt,
      dirty: false,
    ));
  }

  // --- conflict adoption ----------------------------------------------------

  Future<void> _adoptServerTrack(
    SyncMapEntry m,
    Map<String, dynamic> current,
  ) async {
    if (current.isEmpty) return;
    await (db.update(db.tracks)..where((t) => t.id.equals(m.localId))).write(
      TracksCompanion(
        title: Value(current['title'] as String? ?? ''),
        artist: Value(current['artist'] as String?),
        album: Value(current['album'] as String?),
        duration: Value((current['durationMs'] as num?)?.toInt()),
      ),
    );
    await _upsertMap(m.copyWith(
      version: (current['version'] as num?)?.toInt() ?? m.version,
      updatedAt: (current['updatedAt'] as num?)?.toInt() ?? _nowMs(),
      dirty: false,
    ));
  }

  Future<void> _adoptServerPlaylist(
    SyncMapEntry m,
    Map<String, dynamic> current,
  ) async {
    if (current.isEmpty) return;
    await _upsertMap(m.copyWith(
      version: (current['version'] as num?)?.toInt() ?? m.version,
      updatedAt: (current['updatedAt'] as num?)?.toInt() ?? _nowMs(),
      dirty: false,
    ));
  }

  /// Pushes a delete tombstone for a local track, using its stored GUID, then
  /// removes the local mapping. Call before deleting the local row.
  Future<void> pushTrackDelete(int localId) async {
    final m = await _mapFor('track', localId);
    if (m == null) return;
    final t = await (db.select(db.tracks)..where((x) => x.id.equals(localId)))
        .getSingleOrNull();
    try {
      await api.upsertTrack(m.guid, {
        'title': t?.title ?? '',
        'deleted': true,
        'baseVersion': 0, // force: server accepts the tombstone
      });
    } catch (_) {
      // If the push fails, keep the mapping so a later sync can retry.
      return;
    }
    await db.customStatement(
      'DELETE FROM $_table WHERE entity = ? AND local_id = ?',
      ['track', localId],
    );
  }

  /// Pushes a delete tombstone for a local playlist, then drops the mapping.
  Future<void> pushPlaylistDelete(int localId) async {
    final m = await _mapFor('playlist', localId);
    if (m == null) return;
    final p = await (db.select(db.playlists)
          ..where((x) => x.id.equals(localId)))
        .getSingleOrNull();
    try {
      await api.upsertPlaylist(m.guid, {
        'name': p?.name ?? '',
        'entries': <Map<String, dynamic>>[],
        'deleted': true,
        'baseVersion': 0,
      });
    } catch (_) {
      return;
    }
    await db.customStatement(
      'DELETE FROM $_table WHERE entity = ? AND local_id = ?',
      ['playlist', localId],
    );
  }

  // --- one-shot full sync ---------------------------------------------------

  /// Convenience: bootstrap, push local changes, then pull remote changes.
  /// [watermark] is the stored `since` value (0 for a full pull).
  Future<SyncReport> syncOnce({int watermark = 0}) async {
    final report = SyncReport();
    try {
      await ensureInitialized();
      await bootstrapExistingRows();
      await push(report);
      await pull(report, watermark);
      if (report.serverTime == 0) report.serverTime = _nowMs();
    } catch (e) {
      report.error = e.toString();
    }
    return report;
  }

  static int _nowMs() => DateTime.now().millisecondsSinceEpoch;
}

extension on SyncMapEntry {
  SyncMapEntry copyWith({
    String? guid,
    int? version,
    int? updatedAt,
    bool? dirty,
  }) =>
      SyncMapEntry(
        entity: entity,
        localId: localId,
        guid: guid ?? this.guid,
        version: version ?? this.version,
        updatedAt: updatedAt ?? this.updatedAt,
        dirty: dirty ?? this.dirty,
      );
}
