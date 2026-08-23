import 'dart:async';
import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:groovybox/logic/win32_window_ffi.dart';

/// Root widget of the desktop lyrics overlay. Runs inside its own Flutter
/// engine and receives lyric updates from the main window through the
/// per-window method channel.
class DesktopLyricsOverlay extends StatefulWidget {
  final WindowController controller;
  final Map<String, dynamic> launchArgs;

  const DesktopLyricsOverlay({
    super.key,
    required this.controller,
    required this.launchArgs,
  });

  @override
  State<DesktopLyricsOverlay> createState() => _DesktopLyricsOverlayState();
}

class _DesktopLyricsOverlayState extends State<DesktopLyricsOverlay> {
  static const double _barHeight = 84;
  static const double _barWidth = 620;

  int? _hwnd;
  String _currentLine = '';
  String _nextLine = '';
  String _trackTitle = '';
  bool _hovering = false;
  Frame _frame = const Frame(x: 100, y: 100, width: 640, height: 96);
  Timer? _topMostTicker;

  @override
  void initState() {
    super.initState();
    final frameJson = widget.launchArgs['frame'];
    if (frameJson is Map) {
      _frame = Frame.fromJson(frameJson.cast<String, dynamic>());
    }
    widget.controller.setWindowMethodHandler(_handleMethodCall);
    WidgetsBinding.instance.addPostFrameCallback((_) => _setupNativeWindow());
  }

  @override
  void dispose() {
    _topMostTicker?.cancel();
    super.dispose();
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'update':
        final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? {};
        if (!mounted) break;
        setState(() {
          _currentLine = args['current'] as String? ?? '';
          _nextLine = args['next'] as String? ?? '';
          _trackTitle = args['title'] as String? ?? '';
        });
      case 'applyFrame':
        if (call.arguments is Map && _hwnd != null) {
          _frame = Frame.fromJson(
            (call.arguments as Map).cast<String, dynamic>(),
          );
          Win32WindowUtils.moveWindow(
            _hwnd!,
            x: _frame.x,
            y: _frame.y,
            width: _frame.width,
            height: _frame.height,
          );
        }
      case 'show':
        if (_hwnd != null) {
          Win32WindowUtils.showWindow(_hwnd!, show: true);
          Win32WindowUtils.makeTopMost(_hwnd!);
        }
      case 'close':
        await _hideAndNotify();
    }
    return null;
  }

  /// Finds this window's HWND by diffing the process' top-level windows
  /// before/after the native window was spawned, applies layered styling and
  /// restores the persisted frame - all while still hidden to avoid flashing
  /// an unstyled window.
  Future<void> _setupNativeWindow() async {
    final before = Win32WindowUtils.snapshotProcessWindows();
    try {
      await widget.controller.show();
    } catch (_) {}
    // The native view exists as soon as the engine starts; retry briefly in
    // case enumeration races with window creation.
    int? hwnd;
    for (int i = 0; i < 40 && hwnd == null; i++) {
      final diff = Win32WindowUtils.snapshotProcessWindows().difference(before);
      if (diff.isNotEmpty) hwnd = diff.first;
      if (hwnd == null) {
        await Future.delayed(const Duration(milliseconds: 25));
      }
    }
    if (hwnd == null || !mounted) return;

    _hwnd = hwnd;
    Win32WindowUtils.styleAsLyricsOverlay(hwnd, alpha: 216);
    Win32WindowUtils.moveWindow(
      hwnd,
      x: _frame.x,
      y: _frame.y,
      width: _frame.width,
      height: _frame.height,
    );
    Win32WindowUtils.showWindow(hwnd, show: true);

    // Re-assert top-most periodically; other apps may steal the z-order.
    _topMostTicker?.cancel();
    _topMostTicker = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_hwnd != null) Win32WindowUtils.makeTopMost(_hwnd!);
    });
  }

  Future<void> _hideAndNotify() async {
    _topMostTicker?.cancel();
    if (_hwnd != null) {
      Win32WindowUtils.showWindow(_hwnd!, show: false);
    }
    try {
      await _mainWindowController?.invokeMethod('closed');
    } catch (_) {}
  }

  WindowController? get _mainWindowController {
    final mainId = widget.launchArgs['mainWindowId'] as String?;
    if (mainId == null || mainId.isEmpty) return null;
    return WindowController.fromWindowId(mainId);
  }

  void _saveCurrentFrame() {
    if (_hwnd == null) return;
    _frame = Win32WindowUtils.getWindowFrame(_hwnd!);
    _mainWindowController
        ?.invokeMethod('saveFrame', jsonEncode(_frame.toJson()))
        .catchError((_) => null);
  }

  void _startDrag(DragStartDetails details) {
    if (_hwnd == null) return;
    // Blocks until the native move loop finishes, then persist the position.
    Win32WindowUtils.beginCaptionDrag(_hwnd!);
    _saveCurrentFrame();
    HapticFeedback.selectionClick();
  }

  void _toggleSize() {
    if (_hwnd == null) return;
    final current = Win32WindowUtils.getWindowFrame(_hwnd!);
    final compactNow = current.height <= _barHeight + 8;
    final newWidth = compactNow ? 900.0 : _barWidth;
    final newHeight = compactNow ? _barHeight * 1.6 : _barHeight;
    // Keep the bar centered around its previous anchor point.
    Win32WindowUtils.moveWindow(
      _hwnd!,
      x: current.x + ((current.width - newWidth) / 2).round(),
      y: current.y + ((current.height - newHeight) / 2).round(),
      width: newWidth.round(),
      height: newHeight.round(),
    );
    _saveCurrentFrame();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: Scaffold(
        backgroundColor: Colors.transparent,
        body: MouseRegion(
          onEnter: (_) => mounted ? setState(() => _hovering = true) : null,
          onExit: (_) => mounted ? setState(() => _hovering = false) : null,
          child: GestureDetector(
            onPanStart: _startDrag,
            onDoubleTap: _toggleSize,
            child: Container(
              margin: const EdgeInsets.all(6),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xCC101418),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _hovering
                      ? Colors.white24
                      : Colors.white10,
                ),
              ),
              child: Row(
                children: [
                  Expanded(child: _buildLyricText()),
                  AnimatedOpacity(
                    opacity: _hovering ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      color: Colors.white70,
                      tooltip: 'Close',
                      onPressed: () => _hideAndNotify(),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLyricText() {
    final hasLyric = _currentLine.trim().isNotEmpty;
    final mainText = hasLyric
        ? _currentLine
        : (_trackTitle.isEmpty ? 'GroovyBox' : _trackTitle);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            mainText,
            maxLines: 1,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: hasLyric ? Colors.cyanAccent : Colors.white54,
              shadows: const [
                Shadow(blurRadius: 6, color: Colors.black, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
        if (_nextLine.trim().isNotEmpty)
          Text(
            _nextLine,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.65),
              shadows: const [
                Shadow(blurRadius: 4, color: Colors.black, offset: Offset(0, 1)),
              ],
            ),
          ),
      ],
    );
  }
}
