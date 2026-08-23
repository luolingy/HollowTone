import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:groovybox/logic/lyrics_parser.dart';
import 'package:groovybox/logic/win32_window_ffi.dart';
import 'package:groovybox/providers/audio_provider.dart' show CurrentTrackData;
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Marker stored in the sub-window `arguments` so engines can identify
/// themselves as the desktop lyrics overlay.
const String kDesktopLyricsWindowType = 'desktop_lyrics';

/// Manages the desktop lyrics overlay window (Windows only).
///
/// The main window owns lyric computation: it watches the player position,
/// derives the active line and pushes text updates into the overlay engine.
/// Frame and enabled-state are persisted so the overlay restores itself on
/// the next launch.
class DesktopLyricsManager {
  DesktopLyricsManager._();

  static final DesktopLyricsManager instance = DesktopLyricsManager._();

  static const String _prefFrame = 'desktop_lyrics_frame';
  static const String _prefEnabled = 'desktop_lyrics_enabled';

  WindowController? _overlay;
  String? _mainWindowId;
  final List<StreamSubscription<dynamic>> _relaySubs = [];
  CurrentTrackData? Function()? _readTrack;
  Player? _player;

  String _lastPushedKey = '';
  bool _enabled = false;
  bool get isEnabled => _enabled;

  // Parsed-lyrics cache: the position stream ticks constantly, so the LRC
  // JSON must be decoded only once per track instead of on every tick.
  String? _parsedLyricsKey;
  List<LyricsLine>? _parsedLines;

  /// Whether this platform supports the overlay at all.
  static bool get isSupported => !kIsWeb && Platform.isWindows;

  Future<void> attach(
    Player player, {
    required CurrentTrackData? Function() readTrack,
  }) async {
    _readTrack = readTrack;
    _player = player;
    if (!isSupported) return;

    try {
      final main = await WindowController.fromCurrentEngine();
      _mainWindowId = main.windowId;
      await main.setWindowMethodHandler(_handleWindowCall);
    } catch (e) {
      debugPrint('DesktopLyrics: failed to bind main window: $e');
      return;
    }

    // Close overlays left over from a hot restart.
    try {
      for (final controller in await WindowController.getAll()) {
        if (controller.arguments.contains(kDesktopLyricsWindowType)) {
          await controller.invokeMethod('close');
        }
      }
    } catch (e) {
      debugPrint('DesktopLyrics: stale overlay cleanup skipped: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_prefEnabled) ?? false) {
      await enable();
    }
  }

  Future<void> toggle() async => _enabled ? disable() : enable();

  Future<void> enable() async {
    if (!isSupported || _enabled) return;
    _enabled = true;
    SharedPreferences.getInstance().then((p) => p.setBool(_prefEnabled, true));

    try {
      if (_overlay != null) {
        // Reuse the existing (hidden) overlay window.
        await _overlay!.invokeMethod(
          'applyFrame',
          jsonEncode((await _restoreFrame()).toJson()),
        );
      } else {
        final frame = await _restoreFrame();
        _overlay = await WindowController.create(
          WindowConfiguration(
            hiddenAtLaunch: true,
            arguments: jsonEncode({
              'type': kDesktopLyricsWindowType,
              'mainWindowId': _mainWindowId,
              'frame': frame.toJson(),
            }),
          ),
        );
        debugPrint('DesktopLyrics: overlay window ${_overlay!.windowId}');
      }
      _startRelayIfNeeded();
      _pushUpdate(force: true);
      _scheduleRetryPushes();
      // Only show immediately if something is already playing; otherwise the
      // playing-state listener reveals the overlay when playback starts.
      if (_player?.state.playing ?? false) {
        await _overlay!.invokeMethod('show');
      }
    } catch (e) {
      _enabled = false;
      debugPrint('DesktopLyrics: failed to show overlay: $e');
    }
  }

  Future<void> disable() async {
    if (!_enabled) return;
    _enabled = false;
    SharedPreferences.getInstance().then((p) => p.setBool(_prefEnabled, false));
    for (final sub in _relaySubs) {
      await sub.cancel();
    }
    _relaySubs.clear();
    try {
      await _overlay?.invokeMethod('close');
    } catch (_) {}
  }

  /// Handles calls coming back from the overlay window.
  Future<dynamic> _handleWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'saveFrame':
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_prefFrame, call.arguments as String);
        } catch (_) {}
      case 'closed':
        // Keep [_overlay] around so it can be re-shown cheaply.
        break;
    }
    return null;
  }

  Future<Frame> _restoreFrame() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefFrame);
      if (raw != null) {
        return Frame.fromJson(
          (jsonDecode(raw) as Map).cast<String, dynamic>(),
        );
      }
    } catch (_) {}
    return _defaultFrame();
  }

  /// Bottom-center of the primary display by default.
  Frame _defaultFrame() {
    final view = ui.PlatformDispatcher.instance.views.firstOrNull;
    final dpr = view?.devicePixelRatio ?? 1.0;
    final widthPx = (view?.physicalSize.width ?? (1280 * dpr)).round();
    final heightPx = (view?.physicalSize.height ?? (800 * dpr)).round();
    const barWidth = 640;
    const barHeight = 96;
    return Frame(
      x: ((widthPx - barWidth) / 2).round(),
      y: heightPx - barHeight - 120,
      width: barWidth,
      height: barHeight,
    );
  }

  void _startRelayIfNeeded() {
    if (_relaySubs.isNotEmpty || _player == null) return;
    // Push on every position tick and whenever the playlist changes so
    // track switches update the overlay even while paused.
    _relaySubs.add(
      _player!.stream.position.listen((_) => _pushUpdate()),
    );
    _relaySubs.add(
      _player!.stream.playlist.listen((_) => _pushUpdate(force: true)),
    );
    // The overlay is only visible while audio is actually playing.
    _relaySubs.add(
      _player!.stream.playing.listen((playing) async {
        if (!_enabled || _overlay == null) return;
        try {
          await _overlay!.invokeMethod(playing ? 'show' : 'hide');
          if (playing) {
            _pushUpdate(force: true);
            _scheduleRetryPushes();
          }
        } catch (e) {
          debugPrint('DesktopLyrics: visibility sync failed: $e');
        }
      }),
    );
  }

  /// The overlay engine boots asynchronously; repeat the first pushes so
  /// early messages are not lost before its method handler is registered.
  void _scheduleRetryPushes() {
    for (final delay in const [
      Duration(milliseconds: 300),
      Duration(seconds: 1),
      Duration(seconds: 3),
    ]) {
      Timer(delay, () {
        if (_enabled) _pushUpdate(force: true);
      });
    }
  }

  /// Computes the active lyric line and pushes an update when it changed.
  void _pushUpdate({bool force = false}) {
    if (!_enabled || _overlay == null) return;
    final readTrack = _readTrack;
    if (readTrack == null) return;

    final track = readTrack();
    final player = _player!;
    final positionMs =
        player.state.position.inMilliseconds + (track?.lyricsOffset ?? 0);

    String current = '';
    String next = '';
    if (track?.lyrics != null) {
      final key = '${track!.id}:${track.lyrics!.length}';
      if (key != _parsedLyricsKey) {
        _parsedLines = null;
        try {
          final data = LyricsData.fromJsonString(track.lyrics!);
          if (data.type == 'timed') {
            _parsedLines = data.lines;
          }
        } catch (_) {
          // Malformed lyrics simply render as "no lyric".
        }
        _parsedLyricsKey = key;
      }

      final lines = _parsedLines;
      if (lines != null && lines.isNotEmpty) {
        int index = -1;
        for (int i = 0; i < lines.length; i++) {
          if ((lines[i].timeMs ?? 0) <= positionMs) {
            index = i;
          } else {
            break;
          }
        }
        if (index >= 0) current = lines[index].text;
        if (index >= 0 && index + 1 < lines.length) {
          next = lines[index + 1].text;
        }
      }
    }

    final key = '$current\u0000$next\u0000${track?.title ?? ''}';
    if (!force && key == _lastPushedKey) return;
    _lastPushedKey = key;

    _overlay!
        .invokeMethod(
          'update',
          jsonEncode({'current': current, 'next': next, 'title': track?.title}),
        )
        .catchError((_) => null);
  }
}
