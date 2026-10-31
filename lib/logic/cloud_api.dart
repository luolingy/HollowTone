// HollowTone cloud-sync HTTP client.
//
// A thin, strongly-typed wrapper over the personal-server REST API
// (see server/README.md). It performs authentication, incremental sync
// pulls, versioned pushes and resumable chunked uploads, and builds
// token-bearing streaming URLs for the audio player.
//
// This file deliberately avoids code generation so it compiles independently
// of build_runner.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// The server rejected the request with a 409 because the caller's
/// `baseVersion` was stale. [current] carries the server-side row so the
/// caller can merge and retry.
class SyncConflict implements Exception {
  final Map<String, dynamic> current;
  SyncConflict(this.current);
  @override
  String toString() => 'SyncConflict(current=$current)';
}

/// Any non-2xx HTTP response that is not a conflict.
class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);
  @override
  String toString() => 'ApiException($statusCode): $body';
}

/// Result of an authentication call.
class AuthResult {
  final String token;
  final int expiresAt;
  final int userId;
  final String username;
  AuthResult({
    required this.token,
    required this.expiresAt,
    required this.userId,
    required this.username,
  });
}

/// Result of one incremental sync pull.
class SyncPullResult {
  final int serverTime;
  final List<Map<String, dynamic>> tracks;
  final List<Map<String, dynamic>> playlists;
  SyncPullResult({
    required this.serverTime,
    required this.tracks,
    required this.playlists,
  });
}

/// Client for one HollowTone personal server.
class HollowToneApi {
  /// Base URL without a trailing slash, e.g. `http://192.168.1.10:8080`.
  final String baseUrl;
  String? _token;

  final http.Client _http;
  final Duration _timeout;

  HollowToneApi({
    required this.baseUrl,
    String? token,
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  })  : _token = token,
        _http = client ?? http.Client(),
        _timeout = timeout;

  /// The current bearer token, if authenticated.
  String? get token => _token;

  /// Sets the bearer token (e.g. restored from storage at startup).
  set token(String? value) => _token = value;

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers {
    final h = {'Content-Type': 'application/json'};
    if (_token != null && _token!.isNotEmpty) {
      h['Authorization'] = 'Bearer $_token';
    }
    return h;
  }

  // --- Auth -----------------------------------------------------------------

  /// Registers a new account and stores the returned token.
  Future<AuthResult> register(String username, String password) async {
    final res = await _post('/api/v1/auth/register', {
      'username': username,
      'password': password,
    }, auth: false);
    return _authFrom(res);
  }

  /// Logs in and stores the returned token.
  Future<AuthResult> login(String username, String password) async {
    final res = await _post('/api/v1/auth/login', {
      'username': username,
      'password': password,
    }, auth: false);
    return _authFrom(res);
  }

  AuthResult _authFrom(Map<String, dynamic> res) {
    _token = res['token'] as String?;
    final user = (res['user'] as Map).cast<String, dynamic>();
    return AuthResult(
      token: _token ?? '',
      expiresAt: (res['expiresAt'] as num?)?.toInt() ?? 0,
      userId: (user['id'] as num?)?.toInt() ?? 0,
      username: user['username'] as String? ?? '',
    );
  }

  /// Verifies the current token and returns the user id/name.
  Future<Map<String, dynamic>> me() => _get('/api/v1/me');

  /// Lightweight connectivity check; never throws on a non-2xx, returns false.
  Future<bool> healthCheck() async {
    try {
      final res = await _http
          .get(_uri('/healthz'))
          .timeout(const Duration(seconds: 8));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // --- Sync -----------------------------------------------------------------

  /// Pulls everything changed since [sinceMillis] (0 = full library).
  Future<SyncPullResult> sync({int sinceMillis = 0}) async {
    final res = await _get(
      '/api/v1/sync',
      query: {'since': sinceMillis.toString()},
    );
    final tracks = ((res['tracks'] as List?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    final playlists = ((res['playlists'] as List?) ?? [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .toList();
    return SyncPullResult(
      serverTime: (res['serverTime'] as num?)?.toInt() ?? 0,
      tracks: tracks,
      playlists: playlists,
    );
  }

  // --- Tracks ---------------------------------------------------------------

  /// Creates or updates a track. Throws [SyncConflict] on a stale base version.
  Future<Map<String, dynamic>> upsertTrack(
    String guid,
    Map<String, dynamic> body,
  ) =>
      _put('/api/v1/tracks/$guid', body);

  /// Fetches one track.
  Future<Map<String, dynamic>> getTrack(String guid) =>
      _get('/api/v1/tracks/$guid');

  /// Uploads an entire audio file for a track (small/simple path).
  Future<Map<String, dynamic>> attachTrackFile(String guid, File file) async {
    final body = await file.readAsBytes();
    final res = await _http
        .post(
          _uri('/api/v1/tracks/$guid/file'),
          headers: {
            'Content-Type': 'application/octet-stream',
            if (_token != null) 'Authorization': 'Bearer $_token',
          },
          body: body,
        )
        .timeout(const Duration(minutes: 10));
    return _decode(res);
  }

  /// Returns a token-bearing URL the audio player can stream directly from.
  /// Supports HTTP Range so seeking works.
  String streamUrl(String guid) {
    final u = _uri('/api/v1/tracks/$guid/stream',
        {'token': _token ?? ''});
    return u.toString();
  }

  /// Returns a token-bearing URL for a track's cover art.
  String artUrl(String guid) {
    final u = _uri('/api/v1/tracks/$guid/art', {'token': _token ?? ''});
    return u.toString();
  }

  // --- Playlists ------------------------------------------------------------

  /// Creates or updates a playlist. Throws [SyncConflict] on a stale version.
  Future<Map<String, dynamic>> upsertPlaylist(
    String guid,
    Map<String, dynamic> body,
  ) =>
      _put('/api/v1/playlists/$guid', body);

  /// Fetches one playlist.
  Future<Map<String, dynamic>> getPlaylist(String guid) =>
      _get('/api/v1/playlists/$guid');

  // --- Assets ---------------------------------------------------------------

  /// Uploads a standalone cover/lyrics blob; returns `{key, sha256, size, url}`.
  Future<Map<String, dynamic>> uploadAsset(
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    final res = await _http
        .post(
          _uri('/api/v1/assets'),
          headers: {
            'Content-Type': contentType,
            if (_token != null) 'Authorization': 'Bearer $_token',
          },
          body: bytes,
        )
        .timeout(const Duration(minutes: 2));
    return _decode(res);
  }

  // --- Resumable chunked upload --------------------------------------------

  /// Initialises a chunked upload. Returns the server-advertised chunk size
  /// and any chunks already received (for resume).
  Future<({int chunkSize, List<int> received})> initUpload(
    String uploadId, {
    required int totalChunks,
    String target = 'media',
  }) async {
    final res = await _post(
      '/api/v1/uploads/$uploadId/init',
      {'totalChunks': totalChunks, 'target': target},
    );
    final received = ((res['received'] as List?) ?? [])
        .map((e) => (e as num).toInt())
        .toList();
    return (
      chunkSize: (res['chunkSize'] as num?)?.toInt() ?? (8 << 20),
      received: received,
    );
  }

  /// Returns the sorted chunk indices the server already has for [uploadId].
  Future<List<int>> uploadStatus(String uploadId) async {
    final res = await _get('/api/v1/uploads/$uploadId');
    return ((res['received'] as List?) ?? [])
        .map((e) => (e as num).toInt())
        .toList();
  }

  /// Uploads one chunk.
  Future<void> uploadChunk(String uploadId, int index, Uint8List data) async {
    final res = await _http
        .put(
          _uri('/api/v1/uploads/$uploadId/chunks/$index'),
          headers: {
            'Content-Type': 'application/octet-stream',
            if (_token != null) 'Authorization': 'Bearer $_token',
          },
          body: data,
        )
        .timeout(const Duration(minutes: 5));
    _decode(res); // throws on non-2xx
  }

  /// Finalises an upload; optionally binds the finished object to a track.
  Future<Map<String, dynamic>> finalizeUpload(
    String uploadId, {
    required int totalChunks,
    String target = 'media',
    String? guid,
  }) {
    return _post('/api/v1/uploads/$uploadId/finalize', {
      'totalChunks': totalChunks,
      'target': target,
      if (guid != null) 'guid': guid,
    });
  }

  /// Convenience: upload [file] in chunks and bind it to [guid]. Resumes from
  /// whatever the server already holds, then finalises.
  Future<Map<String, dynamic>> uploadFileChunked(
    String guid,
    File file, {
    int chunkSize = 8 << 20,
    void Function(int sent, int total)? onProgress,
  }) async {
    final size = await file.length();
    final total = (size + chunkSize - 1) ~/ chunkSize;
    final uploadId = '${guid}-${size}-${DateTime.now().millisecondsSinceEpoch}';

    final init = await initUpload(uploadId, totalChunks: total);
    final have = init.received.toSet();
    final raf = await file.open();
    try {
      final buf = Uint8List(chunkSize);
      for (var i = 0; i < total; i++) {
        final start = i * chunkSize;
        final len = (start + chunkSize > size) ? size - start : chunkSize;
        await raf.setPosition(start);
        final read = await raf.readInto(buf, 0, len);
        if (!have.contains(i)) {
          await uploadChunk(uploadId, i, Uint8List.sublistView(buf, 0, read));
        }
        onProgress?.call(i + 1, total);
      }
    } finally {
      await raf.close();
    }
    return finalizeUpload(uploadId,
        totalChunks: total, target: 'media', guid: guid);
  }

  void close() => _http.close();

  // --- HTTP plumbing --------------------------------------------------------

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, String>? query,
  }) async {
    final res = await _http
        .get(_uri(path, query), headers: _headers)
        .timeout(_timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool auth = true,
  }) async {
    final res = await _http
        .post(
          _uri(path),
          headers: auth ? _headers : {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);
    return _decode(res);
  }

  Future<Map<String, dynamic>> _put(
    String path,
    Map<String, dynamic> body,
  ) async {
    final res = await _http
        .put(_uri(path), headers: _headers, body: jsonEncode(body))
        .timeout(_timeout);
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final text = res.body.isEmpty ? '{}' : utf8.decode(res.bodyBytes);
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      decoded = null;
    }
    if (res.statusCode == 409) {
      final current = (decoded is Map && decoded['current'] is Map)
          ? (decoded['current'] as Map).cast<String, dynamic>()
          : <String, dynamic>{};
      throw SyncConflict(current);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(res.statusCode, text);
    }
    return (decoded is Map) ? decoded.cast<String, dynamic>() : <String, dynamic>{};
  }
}
