// Cloud-sync configuration and orchestration providers.
//
// Holds the server address, bearer token and sync watermark in
// SharedPreferences (matching the app's existing settings pattern) and exposes
// a notifier that runs SyncService against the configured server.
//
// Hand-written with NotifierProvider (no code generation) so this file
// compiles without build_runner.
library;

import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hollowtone/logic/cloud_api.dart';
import 'package:hollowtone/logic/sync_service.dart';
import 'package:hollowtone/providers/db_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Immutable cloud-sync configuration + status snapshot.
class CloudSyncState {
  final String serverUrl;
  final String username;
  final String? token;
  final bool enabled;
  final bool autoSync;
  final int watermark; // ms; last pulled serverTime
  final DateTime? lastSyncAt;
  final String? lastError;
  final bool syncing;

  const CloudSyncState({
    this.serverUrl = '',
    this.username = '',
    this.token,
    this.enabled = false,
    this.autoSync = true,
    this.watermark = 0,
    this.lastSyncAt,
    this.lastError,
    this.syncing = false,
  });

  bool get isConfigured => serverUrl.isNotEmpty && (token?.isNotEmpty ?? false);

  CloudSyncState copyWith({
    String? serverUrl,
    String? username,
    String? token,
    bool? enabled,
    bool? autoSync,
    int? watermark,
    DateTime? lastSyncAt,
    String? lastError,
    bool? syncing,
    bool clearError = false,
  }) {
    return CloudSyncState(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      token: token ?? this.token,
      enabled: enabled ?? this.enabled,
      autoSync: autoSync ?? this.autoSync,
      watermark: watermark ?? this.watermark,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastError: clearError ? null : (lastError ?? this.lastError),
      syncing: syncing ?? this.syncing,
    );
  }
}

class CloudSyncNotifier extends Notifier<CloudSyncState> {
  static const _kServer = 'cloud_server_url';
  static const _kUser = 'cloud_username';
  static const _kToken = 'cloud_token';
  static const _kEnabled = 'cloud_enabled';
  static const _kAutoSync = 'cloud_auto_sync';
  static const _kWatermark = 'cloud_watermark';
  static const _kLastSync = 'cloud_last_sync_at';

  @override
  CloudSyncState build() {
    // Kick off an async load; state starts empty and is replaced when ready.
    _load();
    return const CloudSyncState();
  }  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt(_kLastSync);
    state = CloudSyncState(
      serverUrl: prefs.getString(_kServer) ?? '',
      username: prefs.getString(_kUser) ?? '',
      token: prefs.getString(_kToken),
      enabled: prefs.getBool(_kEnabled) ?? false,
      autoSync: prefs.getBool(_kAutoSync) ?? true,
      watermark: prefs.getInt(_kWatermark) ?? 0,
      lastSyncAt:
          lastSyncMs != null ? DateTime.fromMillisecondsSinceEpoch(lastSyncMs) : null,
    );
  }

  /// Builds an API client bound to the current configuration, or null.
  HollowToneApi? _client() {
    if (state.serverUrl.isEmpty) return null;
    return HollowToneApi(baseUrl: state.serverUrl, token: state.token);
  }

  /// Authenticates against the configured server and persists the token.
  /// Returns null on success, or an error message on failure.
  Future<String?> login(String serverUrl, String username, String password) async {
    final api = HollowToneApi(baseUrl: serverUrl);
    try {
      final auth = await api.login(username, password);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kServer, serverUrl);
      await prefs.setString(_kUser, username);
      await prefs.setString(_kToken, auth.token);
      await prefs.setBool(_kEnabled, true);
      state = state.copyWith(
        serverUrl: serverUrl,
        username: username,
        token: auth.token,
        enabled: true,
        clearError: true,
      );
      return null;
    } catch (e) {
      return _friendly(e);
    } finally {
      api.close();
    }
  }

  /// Registers a new account on the server and persists the token.
  Future<String?> register(
    String serverUrl,
    String username,
    String password,
  ) async {
    final api = HollowToneApi(baseUrl: serverUrl);
    try {
      final auth = await api.register(username, password);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kServer, serverUrl);
      await prefs.setString(_kUser, username);
      await prefs.setString(_kToken, auth.token);
      await prefs.setBool(_kEnabled, true);
      state = state.copyWith(
        serverUrl: serverUrl,
        username: username,
        token: auth.token,
        enabled: true,
        clearError: true,
      );
      return null;
    } catch (e) {
      return _friendly(e);
    } finally {
      api.close();
    }
  }

  /// Clears credentials and disables sync (does not delete server data).
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kServer);
    await prefs.remove(_kUser);
    await prefs.setBool(_kEnabled, false);
    await prefs.remove(_kWatermark);
    state = state.copyWith(
      serverUrl: '',
      username: '',
      token: null,
      enabled: false,
      watermark: 0,
      clearError: true,
    );
  }

  Future<void> setAutoSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAutoSync, value);
    state = state.copyWith(autoSync: value);
  }

  /// Runs one push+pull cycle and persists the new watermark.
  Future<SyncReport?> syncNow() async {
    if (state.syncing) return null;
    final api = _client();
    if (api == null || state.token == null) {
      state = state.copyWith(lastError: 'Not signed in');
      return null;
    }
    state = state.copyWith(syncing: true, clearError: true);
    try {
      final db = ref.read(databaseProvider);
      final service = SyncService(db: db, api: api);
      final report = await service.syncOnce(watermark: state.watermark);

      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      if (!report.hasError && report.serverTime > 0) {
        await prefs.setInt(_kWatermark, report.serverTime);
      }
      await prefs.setInt(_kLastSync, now.millisecondsSinceEpoch);

      state = state.copyWith(
        syncing: false,
        watermark: report.hasError ? state.watermark : report.serverTime,
        lastSyncAt: now,
        lastError: report.error,
      );
      return report;
    } catch (e) {
      state = state.copyWith(syncing: false, lastError: _friendly(e));
      return null;
    } finally {
      api.close();
    }
  }

  /// Re-initialises the sync engine's tables without performing a full sync.
  /// Useful right after login so the map table exists before first use.
  Future<void> prepare() async {
    final api = _client();
    if (api == null) return;
    try {
      final db = ref.read(databaseProvider);
      await SyncService(db: db, api: api).ensureInitialized();
    } finally {
      api.close();
    }
  }

  String _friendly(Object e) {
    if (e is ApiException) {
      if (e.statusCode == 401) return 'Authentication failed (401)';
      if (e.statusCode == 403) return 'Registration is disabled (403)';
      return 'Server error ${e.statusCode}';
    }
    debugPrint('Cloud sync error: $e');
    return e.toString();
  }
}

/// The cloud-sync configuration/status provider. Kept alive for the app
/// lifetime so startup auto-sync and the settings UI share one instance.
final cloudSyncProvider =
    NotifierProvider<CloudSyncNotifier, CloudSyncState>(CloudSyncNotifier.new);
