import 'package:go_router/go_router.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hollowtone/data/db.dart';
import 'package:hollowtone/data/playlist_repository.dart';
import 'package:hollowtone/ui/screens/album_detail_screen.dart';
import 'package:hollowtone/ui/screens/library_screen.dart';
import 'package:hollowtone/ui/screens/player_screen.dart';
import 'package:hollowtone/ui/screens/playlist_detail_screen.dart';
import 'package:hollowtone/ui/screens/settings_screen.dart';
import 'package:hollowtone/ui/shell.dart';

// Route names
class AppRoutes {
  static const String library = '/';
  static const String player = '/player';
  static const String settings = '/settings';
  static const String albumDetail = '/album';
  static const String playlistDetail = '/playlist';
}

// Router provider that can be accessed from anywhere in the app
final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoutes.library,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Shell(child: child),
        routes: [
          GoRoute(
            path: AppRoutes.library,
            builder: (context, state) => const LibraryScreen(),
          ),
          GoRoute(
            path: AppRoutes.player,
            builder: (context, state) => const PlayerScreen(),
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: AppRoutes.albumDetail,
            builder: (context, state) {
              final album = state.extra as AlbumData;
              return AlbumDetailScreen(album: album);
            },
          ),
          GoRoute(
            path: AppRoutes.playlistDetail,
            builder: (context, state) {
              final playlist = state.extra as Playlist;
              return PlaylistDetailScreen(playlist: playlist);
            },
          ),
        ],
      ),
    ],
  );
});
