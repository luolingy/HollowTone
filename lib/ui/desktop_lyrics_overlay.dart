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

  /// Must match [Win32WindowUtils.lyricsColorKeyValue]: every pixel painted
  /// with this exact color becomes fully transparent in the layered window.
  static const Color _colorKey = Color(0xFF010203);

  // Solid colors only - any translucency would blend towards the color-key
  // and produce green fringes.
  static const Color _barColor = Color(0xFF12161C);
  static const Color _barBorderIdle = Color(0xFF343A43);
  static const Color _barBorderHover = Color(0xFF586069);
  static const Color _secondaryText = Color(0xFF9BA2AB);
  static const Color _iconColor = Color(0xFFB9BFC8);

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
      case 'hide':
        if (_hwnd != null) {
          Win32WindowUtils.showWindow(_hwnd!, show: false);
        }
      case 'close':
        await _hideAndNotify();
    }
    return null;
  }

  /// Locates this window's HWND via the dedicated window class used by
  /// desktop_multi_window sub windows, applies layered styling and restores
  /// the persisted frame - all while still hidden to avoid flashing an
  /// unstyled window.
  Future<void> _setupNativeWindow() async {
    int? hwnd;
    for (int i = 0; i < 80 && hwnd == null; i++) {
      hwnd = Win32WindowUtils.findFirstWindowOfClass(
        Win32WindowUtils.multiWindowClassName,
      );
      if (hwnd == null) {
        await Future.delayed(const Duration(milliseconds: 25));
      }
    }
    if (hwnd == null) {
      debugPrint('DesktopLyricsOverlay: native window not found');
      return;
    }

    _hwnd = hwnd;
    debugPrint('DesktopLyricsOverlay: styling hwnd=$hwnd');
    Win32WindowUtils.styleAsLyricsOverlay(hwnd);
    Win32WindowUtils.moveWindow(
      hwnd,
      x: _frame.x,
      y: _frame.y,
      width: _frame.width,
      height: _frame.height,
    );
    try {
      await widget.controller.show();
    } catch (_) {}
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
        backgroundColor: _colorKey,
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
                color: _barColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _hovering ? _barBorderHover : _barBorderIdle,
                ),
              ),
              child: Row(
                children: [
                  Expanded(child: _buildLyricText()),
                  if (_hovering)
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, size: 18),
                      color: _iconColor,
                      tooltip: 'Close',
                      onPressed: () => _hideAndNotify(),
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
              color: hasLyric ? const Color(0xFF4DD0E1) : _secondaryText,
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
            style: const TextStyle(
              fontSize: 13,
              color: _secondaryText,
              shadows: [
                Shadow(blurRadius: 4, color: Colors.black, offset: Offset(0, 1)),
              ],
            ),
          ),
      ],
    );
  }
}
