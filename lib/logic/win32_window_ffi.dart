import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Minimal user32/kernel32 bindings used by the desktop lyrics overlay:
/// finding the overlay HWND inside this process, layered-window styling,
/// top-most placement, frame manipulation and the caption-drag move trick.
class Win32WindowUtils {
  Win32WindowUtils._();

  // Window style constants.
  static const int gwlExStyle = -20;
  static const int wsExLayered = 0x00080000;
  static const int wsExToolWindow = 0x00000080;
  static const int wsExNoActivate = 0x08000000;
  static const int lwaAlpha = 0x00000002;
  static const int hwndTopmost = -1;
  static const int swpNoSize = 0x0001;
  static const int swpNoMove = 0x0002;
  static const int swpNoActivate = 0x0010;
  static const int swHide = 0;
  static const int swShowNa = 8;
  static const int wmNcLButtonDown = 0x00A1;
  static const int htCaption = 2;

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

  static final int Function() _getCurrentProcessId = _kernel32
      .lookupFunction<Uint32 Function(), int Function()>('GetCurrentProcessId');

  static final int Function(int, int) _getWindowLongPtr =
      _user32.lookupFunction<IntPtr Function(IntPtr, Int32), int Function(
        int,
        int,
      )>('GetWindowLongPtrW');

  static final int Function(int, int, int) _setWindowLongPtr =
      _user32.lookupFunction<
        IntPtr Function(IntPtr, Int32, IntPtr),
        int Function(int, int, int)
      >('SetWindowLongPtrW');

  static final int Function(int, int, int, int) _setLayeredWindowAttributes =
      _user32.lookupFunction<
        Int32 Function(IntPtr, Uint32, Uint8, Uint32),
        int Function(int, int, int, int)
      >('SetLayeredWindowAttributes');

  static final int Function(int, int, int, int, int, int, int) _setWindowPos =
      _user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)
      >('SetWindowPos');

  static final int Function(int, Pointer<Rect>) _getWindowRect =
      _user32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Rect>),
        int Function(int, Pointer<Rect>)
      >('GetWindowRect');

  static final int Function(int, int, int, int) _sendMessageW =
      _user32.lookupFunction<
        IntPtr Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)
      >('SendMessageW');

  static final int Function(int, int) _showWindow =
      _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(
        int,
        int,
      )>('ShowWindow');

  static final int Function(
    Pointer<NativeFunction<EnumWindowsProcNative>>,
    int,
  )
  _enumWindows = _user32.lookupFunction<
    Int32 Function(Pointer<NativeFunction<EnumWindowsProcNative>>, IntPtr),
    int Function(Pointer<NativeFunction<EnumWindowsProcNative>>, int)
  >('EnumWindows');

  static final int Function(int, Pointer<Uint32>) _getWindowThreadProcessId =
      _user32.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)
      >('GetWindowThreadProcessId');

  static final int Function(int) _isWindowVisible =
      _user32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'IsWindowVisible',
      );

  /// HWNDs collected by the last [snapshotVisibleWindows] call. EnumWindows
  /// invokes the callback synchronously on the calling thread, so this list
  /// is complete by the time it returns.
  static final List<int> _enumResults = <int>[];

  /// Collects the HWNDs of all top-level windows of this process, visible
  /// or not. Used to identify freshly created (still hidden) windows.
  static Set<int> snapshotProcessWindows() {
    _enumResults.clear();
    _enumWindows(
      Pointer.fromFunction<EnumWindowsProcNative>(_enumCallback, false),
      0,
    );
    final result = <int>{};
    final pid = _getCurrentProcessId();
    final pidPtr = calloc<Uint32>();
    try {
      for (final hwnd in _enumResults) {
        pidPtr.value = 0;
        _getWindowThreadProcessId(hwnd, pidPtr);
        if (pidPtr.value == pid) {
          result.add(hwnd);
        }
      }
    } finally {
      calloc.free(pidPtr);
    }
    return result;
  }

  /// Collects the HWNDs of all visible top-level windows of this process.
  static Set<int> snapshotVisibleWindows() {
    _enumResults.clear();
    _enumWindows(
      Pointer.fromFunction<EnumWindowsProcNative>(_enumCallback, false),
      0,
    );
    final result = <int>{};
    final pid = _getCurrentProcessId();
    final pidPtr = calloc<Uint32>();
    try {
      for (final hwnd in _enumResults) {
        pidPtr.value = 0;
        _getWindowThreadProcessId(hwnd, pidPtr);
        if (pidPtr.value == pid && _isWindowVisible(hwnd) != 0) {
          result.add(hwnd);
        }
      }
    } finally {
      calloc.free(pidPtr);
    }
    return result;
  }

  static bool _enumCallback(int hwnd, int lParam) {
    _enumResults.add(hwnd);
    return true;
  }

  /// Applies layered / tool-window / no-activate styles and makes [hwnd]
  /// always-on-top with the given uniform opacity.
  static void styleAsLyricsOverlay(int hwnd, {int alpha = 230}) {
    final exStyle = _getWindowLongPtr(hwnd, gwlExStyle);
    _setWindowLongPtr(
      hwnd,
      gwlExStyle,
      exStyle | wsExLayered | wsExToolWindow | wsExNoActivate,
    );
    _setLayeredWindowAttributes(hwnd, 0, alpha, lwaAlpha);
    makeTopMost(hwnd);
  }

  static void makeTopMost(int hwnd) {
    _setWindowPos(
      hwnd,
      hwndTopmost,
      0,
      0,
      0,
      0,
      swpNoMove | swpNoSize | swpNoActivate,
    );
  }

  static void moveWindow(
    int hwnd, {
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    _setWindowPos(hwnd, 0, x, y, width, height, swpNoActivate);
  }

  /// Returns the current window frame in physical pixels.
  static Frame getWindowFrame(int hwnd) {
    final rect = calloc<Rect>();
    try {
      _getWindowRect(hwnd, rect);
      return Frame(
        x: rect.ref.left,
        y: rect.ref.top,
        width: rect.ref.right - rect.ref.left,
        height: rect.ref.bottom - rect.ref.top,
      );
    } finally {
      calloc.free(rect);
    }
  }

  static void showWindow(int hwnd, {required bool show}) {
    _showWindow(hwnd, show ? swShowNa : swHide);
  }

  /// Starts the native window-move loop, as if the user grabbed the title
  /// bar. Blocks until the drag finishes (the move loop runs modally).
  static void beginCaptionDrag(int hwnd) {
    _sendMessageW(hwnd, wmNcLButtonDown, htCaption, 0);
  }
}

/// A window rectangle in physical screen pixels.
class Frame {
  final int x;
  final int y;
  final int width;
  final int height;

  const Frame({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  Map<String, dynamic> toJson() =>
      {'x': x, 'y': y, 'width': width, 'height': height};

  static Frame fromJson(Map<String, dynamic> json) => Frame(
    x: json['x'] as int? ?? 100,
    y: json['y'] as int? ?? 100,
    width: json['width'] as int? ?? 640,
    height: json['height'] as int? ?? 96,
  );
}

/// WinAPI RECT layout used by GetWindowRect.
final class Rect extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

typedef EnumWindowsProcNative = Bool Function(IntPtr hwnd, IntPtr lParam);
