import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// Online source used for metadata / lyrics / cover lookups.
enum OnlineChannel { netease, qq }

/// A song returned by an online channel search.
class OnlineMatch {
  final String songId;
  final String title;
  final String artist;
  final String? album;
  final int? durationMs;

  const OnlineMatch({
    required this.songId,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs,
  });
}

/// Abstract channel mirroring MusicPlayer2's lyric download classes
/// (CNeteaseLyricDownload / CQQMusicLyricDownload).
abstract class OnlineMetadataChannel {
  Dio get session => Dio();

  String get name;

  Future<List<OnlineMatch>> search(
    String title, {
    String? artist,
    int limit = 20,
  });

  /// Returns raw lyric text (LRC when available), `null` when the channel has
  /// no lyrics for [songId].
  Future<String?> fetchLyric(String songId);

  /// Returns a downloadable cover image URL, `null` when unavailable.
  Future<String?> fetchCoverUrl(String songId);

  Future<Uint8List?> downloadCover(String songId) async {
    try {
      final url = await fetchCoverUrl(songId);
      if (url == null || url.isEmpty) return null;
      final response = await session.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      if (response.statusCode != 200 || response.data == null) return null;
      return Uint8List.fromList(response.data!);
    } catch (e) {
      debugPrint('$name: cover download failed: $e');
      return null;
    }
  }
}

/// NetEase Cloud Music channel.
class NeteaseChannel extends OnlineMetadataChannel {
  static const String _searchUrl = 'http://music.163.com/api/search/get/';
  static const String _songDetailUrl =
      'http://music.163.com/api/song/detail/';
  static const String _lyricMediaUrl = 'http://music.163.com/api/song/media';

  @override
  String get name => 'NetEase';

  @override
  Future<List<OnlineMatch>> search(
    String title, {
    String? artist,
    int limit = 20,
  }) async {
    final keyword = artist == null || artist.trim().isEmpty
        ? title.trim()
        : '${title.trim()} ${artist.trim()}';
    // MusicPlayer2 performs a form POST against this legacy endpoint.
    final response = await session.post<dynamic>(
      _searchUrl,
      queryParameters: {'s': keyword, 'limit': limit, 'type': 1, 'offset': 0},
      options: Options(contentType: 'application/x-www-form-urlencoded'),
    );
    final data = response.data is String
        ? jsonDecode(response.data as String)
        : response.data;
    final songs = data?['result']?['songs'];
    if (songs is! List) return const [];
    return [
      for (final song in songs.whereType<Map>())
        OnlineMatch(
          songId: '${song['id']}',
          title: '${song['name'] ?? ''}',
          artist: [
            for (final a in (song['artists'] as List? ?? []))
              if (a is Map && a['name'] != null) '${a['name']}',
          ].join('/'),
          album: song['album'] is Map ? '${song['album']['name']}' : null,
          durationMs: song['duration'] is num ? (song['duration'] as num).toInt() : null,
        ),
    ];
  }

  @override
  Future<String?> fetchLyric(String songId) async {
    final response = await session.get<Map<String, dynamic>>(
      _lyricMediaUrl,
      queryParameters: {'id': songId},
    );
    final lyric = response.data?['lrc']?['lyric'];
    return lyric is String && lyric.isNotEmpty ? lyric : null;
  }

  @override
  Future<String?> fetchCoverUrl(String songId) async {
    final response = await session.get<Map<String, dynamic>>(
      _songDetailUrl,
      queryParameters: {'id': songId, 'ids': '[$songId]', 'csrf_token': ''},
    );
    final songs = response.data?['songs'];
    if (songs is! List || songs.isEmpty) return null;
    final picUrl = (songs.first as Map)['album']?['picUrl'];
    return picUrl is String && picUrl.isNotEmpty ? picUrl : null;
  }
}

/// QQ Music channel.
class QqChannel extends OnlineMetadataChannel {
  static const String _searchUrl =
      'https://c.y.qq.com/soso/fcgi-bin/client_search_cp';
  static const String _singleSongUrl =
      'https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg';
  static const String _lyricUrl =
      'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg';
  static const String _coverUrlTemplate =
      'http://y.gtimg.cn/music/photo_new/T002R800x800M000%s.jpg';

  static const Map<String, String> _headers = {
    'Referer': 'https://y.qq.com/',
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  };

  @override
  String get name => 'QQ Music';

  @override
  Future<List<OnlineMatch>> search(
    String title, {
    String? artist,
    int limit = 20,
  }) async {
    final keyword = artist == null || artist.trim().isEmpty
        ? title.trim()
        : '${title.trim()} ${artist.trim()}';
    final response = await session.get<Map<String, dynamic>>(
      _searchUrl,
      queryParameters: {'p': 1, 'n': limit, 'w': keyword, 'format': 'json'},
      options: Options(headers: _headers),
    );
    final list = response.data?['data']?['song']?['list'];
    if (list is! List) return const [];
    return [
      for (final song in list.whereType<Map>())
        OnlineMatch(
          songId: '${song['songmid'] ?? ''}',
          title: '${song['songname'] ?? ''}',
          artist: [
            for (final s in (song['singer'] as List? ?? []))
              if (s is Map && s['name'] != null) '${s['name']}',
          ].join(';'),
          album: song['albumname'] != null ? '${song['albumname']}' : null,
          durationMs: song['interval'] is num
              ? (song['interval'] as num).toInt() * 1000
              : null,
        ),
    ].where((m) => m.songId.isNotEmpty).toList();
  }

  @override
  Future<String?> fetchLyric(String songId) async {
    final response = await session.get<Map<String, dynamic>>(
      _lyricUrl,
      queryParameters: {
        'songmid': songId,
        'format': 'json',
        'nobase64': 1,
      },
      options: Options(headers: _headers),
    );
    final lyric = response.data?['lyric'];
    if (lyric is! String || lyric.isEmpty) return null;
    final trans = response.data?['trans'];
    return trans is String && trans.isNotEmpty ? '$lyric\n$trans' : lyric;
  }

  @override
  Future<String?> fetchCoverUrl(String songId) async {
    final response = await session.get<List<dynamic>>(
      _singleSongUrl,
      queryParameters: {'songmid': songId, 'format': 'json'},
      options: Options(headers: _headers),
    );
    final data = response.data;
    if (data == null || data.isEmpty) return null;
    final first = data.first;
    if (first is! Map) return null;
    final album = first['album'];
    if (album is! Map) return null;
    final albumMid = album['mid'];
    if (albumMid is! String || albumMid.isEmpty) return null;
    return _coverUrlTemplate.replaceFirst('%s', albumMid);
  }
}

OnlineMetadataChannel metadataChannelImpl(OnlineChannel channel) =>
    switch (channel) {
      OnlineChannel.netease => NeteaseChannel(),
      OnlineChannel.qq => QqChannel(),
    };
