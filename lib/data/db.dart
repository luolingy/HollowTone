import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'db.g.dart';

class Tracks extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text()();
  TextColumn get artist => text().nullable()();
  TextColumn get album => text().nullable()();
  IntColumn get duration => integer().nullable()(); // Duration in milliseconds
  TextColumn get path => text().unique()();
  TextColumn get artUri => text().nullable()(); // Path to local cover art
  TextColumn get lyrics => text().nullable()(); // JSON formatted lyrics
  IntColumn get lyricsOffset => integer().withDefault(
    const Constant(0),
  )(); // Offset in milliseconds for lyrics timing
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

class Playlists extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class PlaylistEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get playlistId => integer().references(Playlists, #id)();
  IntColumn get trackId =>
      integer().references(Tracks, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer().withDefault(const Constant(0))();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

class WatchFolders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get path => text().unique()();
  TextColumn get name => text()();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  BoolColumn get recursive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get lastScanned => dateTime().nullable()();
}

class RemoteProviders extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get serverUrl => text().unique()();
  TextColumn get name => text()();
  TextColumn get username => text()();
  TextColumn get password =>
      text()(); // Note: In production, this should be encrypted
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  DateTimeColumn get addedAt => dateTime().withDefault(currentDateAndTime)();
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
  tables: [
    Tracks,
    Playlists,
    PlaylistEntries,
    WatchFolders,
    RemoteProviders,
    AppSettings,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 8; // Bump version for playlist entry positions

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: (Migrator m, int from, int to) async {
        if (from < 2) {
          await m.addColumn(tracks, tracks.artUri);
        }
        if (from < 3) {
          await m.createTable(playlists);
          await m.createTable(playlistEntries);
        }
        if (from < 4) {
          await m.addColumn(tracks, tracks.lyrics);
        }
        if (from < 5) {
          await m.addColumn(tracks, tracks.lyricsOffset);
        }
        if (from < 6) {
          // Create tables for watch folders and settings
          await m.createTable(watchFolders);
          await m.createTable(appSettings);
        }
        if (from < 7) {
          // Create table for remote providers
          await m.createTable(remoteProviders);
        }
        if (from < 8) {
          // Custom ordering for playlist entries
          await m.addColumn(playlistEntries, playlistEntries.position);
        }
      },
    );
  }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'hollowtone_db',
      native: DriftNativeOptions(databasePath: _resolveDatabasePath),
    );
  }

  /// Resolves the SQLite file path, renaming a database written under the old
  /// `groovybox_db` name so libraries imported before the rename keep working.
  static Future<String> _resolveDatabasePath() async {
    final directory = await getApplicationDocumentsDirectory();
    final path = p.join(directory.path, 'hollowtone_db.sqlite');
    if (!await File(path).exists()) {
      final legacy = File(p.join(directory.path, 'groovybox_db.sqlite'));
      if (await legacy.exists()) {
        await legacy.rename(path);
      }
    }
    return path;
  }
}
