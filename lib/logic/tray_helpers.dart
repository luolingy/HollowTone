import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Keeps the app resident in the system tray on desktop platforms:
/// - Closing the window hides it instead of quitting, so playback continues.
/// - Left-clicking the tray icon restores the window.
/// - Right-clicking opens a context menu (show window / quit).
final trayWindowHandler = TrayWindowHandler();

class TrayWindowHandler with TrayListener, WindowListener {
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) return;

    _initialized = true;
    trayManager.addListener(this);
    windowManager.addListener(this);

    // Intercept window close events so they can be turned into hides.
    try {
      await windowManager.setPreventClose(true);
    } catch (e) {
      debugPrint('Tray: failed to prevent window close: $e');
    }

    await refreshTray();
  }

  Future<void> refreshTray() async {
    final icon = Platform.isWindows
        ? 'assets/images/icon.ico'
        : 'assets/images/icon.png';
    try {
      await trayManager.setIcon(icon);
      await trayManager.setToolTip(tr('hollowTone'));
      await trayManager.setContextMenu(await _buildMenu());
    } catch (e) {
      debugPrint('Tray: setup failed: $e');
    }
  }

  Future<Menu> _buildMenu() async {
    return Menu(
      items: [
        MenuItem(
          key: 'show',
          label: tr('openMainWindow'),
          onClick: (_) => showMainWindow(),
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'quit',
          label: tr('quit'),
          onClick: (_) async {
            // Allow the window to actually close this time, then exit.
            await windowManager.setPreventClose(false);
            await windowManager.destroy();
          },
        ),
      ],
    );
  }

  void showMainWindow() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    showMainWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onWindowClose() async {
    // Hide to tray instead of quitting so playback keeps running.
    await windowManager.hide();
  }
}
