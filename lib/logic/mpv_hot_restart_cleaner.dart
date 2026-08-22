import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Cleans up libmpv handles left behind by a previous (dead) isolate after a
/// hot restart, before media_kit's own [NativeReferenceHolder] touches them.
///
/// Why this is needed:
/// On hot restart media_kit sends a `quit` command to stale mpv handles.
/// However those handles still carry a wakeup callback registered via
/// `mpv_set_wakeup_callback`, pointing into the now-dead isolate. When libmpv
/// fires events during teardown, the Dart VM aborts with:
/// "Callback invoked after it has been deleted." (runtime_entry.cc)
///
/// The fix: neutralize the wakeup callback FIRST, then send `quit`.
class MpvHotRestartCleaner {
  MpvHotRestartCleaner._();

  /// Must mirror media_kit's NativeReferenceHolder internals.
  static const int _kReferenceBufferSize = 512;
  static const String _kFileStem =
      'com.alexmercerind.media_kit.NativeReferenceHolder';

  /// Candidate shared library names for libmpv per platform.
  static const List<String> _kLibraryNames = [
    'libmpv-2.dll',
    'mpv-2.dll',
    'mpv-1.dll',
    'libmpv.so',
    'libmpv.dylib',
  ];

  static void clean() {
    if (!kDebugMode) return;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    try {
      final marker = File(
        p.join(Directory.systemTemp.path, '$_kFileStem.$pid'),
      );
      if (!marker.existsSync()) return;

      final addressText = marker.readAsStringSync().trim();
      final int bufferAddress = int.tryParse(addressText) ?? 0;
      try {
        marker.deleteSync();
      } catch (_) {}
      if (bufferAddress == 0) return;

      final DynamicLibrary? dylib = _openLibmpv();
      if (dylib == null) return;

      final setWakeupCallback = dylib
          .lookupFunction<
            Void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
            void Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
          >('mpv_set_wakeup_callback');
      final commandString =
          dylib
              .lookupFunction<
                Int32 Function(Pointer<Void>, Pointer<Utf8>),
                int Function(Pointer<Void>, Pointer<Utf8>)
              >('mpv_command_string');

      final buffer = Pointer<IntPtr>.fromAddress(bufferAddress);
      final staleHandles = <Pointer<Void>>[];
      for (int i = 0; i < _kReferenceBufferSize; i++) {
        final slot = buffer + i;
        final int handleAddress = slot.value;
        slot.value = 0;
        if (handleAddress != 0) {
          staleHandles.add(Pointer.fromAddress(handleAddress));
        }
      }

      if (staleHandles.isEmpty) return;
      debugPrint(
        '[MpvHotRestartCleaner] Disposing ${staleHandles.length} stale mpv handle(s)...',
      );

      final cmd = 'quit'.toNativeUtf8();
      try {
        for (final ctx in staleHandles) {
          // Clear the wakeup callback so libmpv cannot invoke a callable that
          // belonged to the dead isolate during teardown.
          setWakeupCallback(ctx, nullptr, nullptr);
          commandString(ctx, cmd.cast());
        }
      } finally {
        calloc.free(cmd);
      }
    } catch (e) {
      debugPrint('[MpvHotRestartCleaner] Skipped: $e');
    }
  }

  static DynamicLibrary? _openLibmpv() {
    for (final name in _kLibraryNames) {
      try {
        return DynamicLibrary.open(name);
      } catch (_) {}
    }
    return null;
  }
}
