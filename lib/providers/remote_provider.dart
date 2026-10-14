import 'package:flutter/foundation.dart';
import 'package:hollowtone/data/db.dart';
import 'package:hollowtone/providers/db_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:drift/drift.dart';
import 'package:jellyfin_dart/jellyfin_dart.dart';

// Simple remote provider using Riverpod
final remoteProvidersProvider = FutureProvider<List<RemoteProvider>>((
  ref,
) async {
  final db = ref.read(databaseProvider);
  return await (db.select(
    db.remoteProviders,
  )..orderBy([(t) => OrderingTerm(expression: t.addedAt)])).get();
});

final activeRemoteProvidersProvider = Provider<List<RemoteProvider>>((ref) {
  final remoteProvidersAsync = ref.watch(remoteProvidersProvider);
  return remoteProvidersAsync.when(
    data: (providers) =>
        providers.where((provider) => provider.isActive).toList(),
    loading: () => [],
    error: (_, _) => [],
  );
});

class RemoteProviderService {
  final Ref ref;

  RemoteProviderService(this.ref);

  Future<void> addRemoteProvider(
    String serverUrl,
    String username,
    String password, {
    String? name,
  }) async {
    final db = ref.read(databaseProvider);
    final providerName = name ?? Uri.parse(serverUrl).host;

    await db
        .into(db.remoteProviders)
        .insert(
          RemoteProvidersCompanion.insert(
            serverUrl: serverUrl,
            name: providerName,
            username: username,
            password: password,
          ),
        );

    // Invalidate the provider to refresh UI
    ref.invalidate(remoteProvidersProvider);
  }

  Future<void> removeRemoteProvider(int providerId) async {
    final db = ref.read(databaseProvider);

    await (db.delete(
      db.remoteProviders,
    )..where((t) => t.id.equals(providerId))).go();

    // Invalidate the provider to refresh UI
    ref.invalidate(remoteProvidersProvider);
  }

  Future<void> toggleRemoteProvider(int providerId, bool isActive) async {
    final db = ref.read(databaseProvider);

    await (db.update(db.remoteProviders)..where((t) => t.id.equals(providerId)))
        .write(RemoteProvidersCompanion(isActive: Value(isActive)));

    // Invalidate the provider to refresh UI
    ref.invalidate(remoteProvidersProvider);
  }

  Future<void> indexRemoteProvider(int providerId) async {
    final db = ref.read(databaseProvider);

    // Get provider details
    final provider = await (db.select(
      db.remoteProviders,
    )..where((t) => t.id.equals(providerId))).getSingleOrNull();

    if (provider == null) {
      throw Exception('Remote provider not found: $providerId');
    }

    if (!provider.isActive) {
      debugPrint('Provider $providerId is not active, skipping indexing');
      return;
    }

    try {
      // Create Jellyfin client
      final client = JellyfinDart(basePathOverride: provider.serverUrl);

      // Set device info
      client.setDeviceId('hollowtone-$providerId');
      client.setVersion('1.0.0');

      // Authenticate
      final userApi = client.getUserApi();
      final authResponse = await userApi.authenticateUserByName(
        authenticateUserByName: AuthenticateUserByName(
          username: provider.username,
          pw: provider.password,
        ),
      );

      final token = authResponse.data?.accessToken;
      if (token == null) {
        throw Exception('Authentication failed for provider ${provider.name}');
      }

      client.setToken(token);

      // Fetch music items
      final itemsApi = client.getItemsApi();
      final musicItems = await itemsApi.getItems(
        includeItemTypes: [BaseItemKind.audio],
        recursive: true,
        fields: [
          ItemFields.path,
          ItemFields.mediaStreams,
          ItemFields.mediaSources,
          ItemFields.genres,
          ItemFields.tags,
          ItemFields.overview,
        ],
      );

      final items = musicItems.data?.items ?? [];

      // Convert to tracks and store
      for (final item in items) {
        await _addRemoteTrack(db, provider, item, token);
      }

      debugPrint('Indexed $items.length tracks from $provider.name');
    } catch (e) {
      debugPrint('Error indexing remote provider $provider.name: $e');
      rethrow;
    }
  }

  Future<void> _addRemoteTrack(
    AppDatabase db,
    RemoteProvider provider,
    BaseItemDto item,
    String token,
  ) async {
    // Generate secure protocol URL instead of exposing API key
    final streamUrl =
        '$remoteStreamScheme://remote/jellyfin/${provider.id}/${item.id}';

    // Extract metadata
    final title = item.name ?? 'Unknown Title';

    // Better artist extraction: prefer album artist, then track artists
    final artist =
        item.albumArtist ??
        (item.artists?.isNotEmpty == true ? item.artists!.join(', ') : null) ??
        'Unknown Artist';

    final album = item.album ?? 'Unknown Album';
    final duration =
        (item.runTimeTicks ?? 0) ~/ 10000; // Convert ticks to milliseconds

    // Generate album art URL (try Primary image)
    final artUri =
        '${provider.serverUrl}/Items/${item.id}/Images/Primary?api_key=$token';

    // Extract overview/description as lyrics placeholder if no real lyrics
    final overview = item.overview;

    // Check if track already exists
    final existingTrack = await (db.select(
      db.tracks,
    )..where((t) => t.path.equals(streamUrl))).getSingleOrNull();

    final trackCompanion = TracksCompanion(
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      duration: Value(duration),
      artUri: Value(artUri),
      lyrics: Value(overview), // Store overview as placeholder for lyrics
      addedAt: Value(DateTime.now()),
    );

    if (existingTrack != null) {
      // Update existing track
      await (db.update(
        db.tracks,
      )..where((t) => t.id.equals(existingTrack.id))).write(trackCompanion);
    } else {
      // Insert new track
      await db
          .into(db.tracks)
          .insert(
            trackCompanion.copyWith(
              path: Value(streamUrl), // Remote streaming URL
            ),
            mode: InsertMode.insertOrIgnore,
          );
    }
  }
}

/// URI scheme used by the remote-stream protocol paths stored on tracks.
const remoteStreamScheme = 'hollowtone';

/// Legacy remote-stream scheme, still accepted for tracks imported before the
/// rename. Remove it once those libraries have been re-indexed.
const legacyRemoteStreamScheme = 'groovybox';

/// Whether [scheme] is a remote-stream protocol scheme this app handles.
bool isRemoteStreamScheme(String scheme) =>
    scheme == remoteStreamScheme || scheme == legacyRemoteStreamScheme;

/// Whether [path] is a remote-stream protocol path this app handles.
bool isRemoteStreamPath(String path) =>
    path.startsWith('$remoteStreamScheme://') ||
    path.startsWith('$legacyRemoteStreamScheme://');

// URL resolver for secure protocol URLs
class RemoteUrlResolver {
  final Ref ref;

  // Token cache: providerId -> {token: string, expiresAt: DateTime}
  final Map<int, Map<String, dynamic>> _tokenCache = {};

  RemoteUrlResolver(this.ref);

  /// Resolves a HollowTone protocol URL to an actual streaming URL
  Future<String?> resolveUrl(String protocolUrl) async {
    final uri = Uri.parse(protocolUrl);
    if (!isRemoteStreamScheme(uri.scheme) || uri.host != 'remote') {
      return null; // Not a protocol URL we handle
    }

    final pathSegments = uri.pathSegments;
    if (pathSegments.length < 3 || pathSegments[0] != 'jellyfin') {
      return null;
    }

    final providerId = int.tryParse(pathSegments[1]);
    final itemId = pathSegments[2];

    if (providerId == null || itemId.isEmpty) {
      return null;
    }

    final db = ref.read(databaseProvider);

    // Get provider details
    final provider = await (db.select(
      db.remoteProviders,
    )..where((t) => t.id.equals(providerId))).getSingleOrNull();

    if (provider == null || !provider.isActive) {
      return null;
    }

    try {
      // Get or refresh token
      final token = await _getToken(providerId, provider);

      if (token == null) {
        return null;
      }

      // Return the actual streaming URL
      return '${provider.serverUrl}/Audio/$itemId/stream.mp3?api_key=$token&static=true';
    } catch (e) {
      debugPrint('Error resolving URL $protocolUrl: $e');
      return null;
    }
  }

  /// Get cached token or authenticate to get a new one
  Future<String?> _getToken(int providerId, RemoteProvider provider) async {
    // Check if we have a cached token that's still valid
    final cached = _tokenCache[providerId];
    if (cached != null) {
      final expiresAt = cached['expiresAt'] as DateTime?;
      if (expiresAt != null && DateTime.now().isBefore(expiresAt)) {
        return cached['token'] as String?;
      }
    }

    // Token is expired or missing, authenticate
    try {
      final client = JellyfinDart(basePathOverride: provider.serverUrl);
      client.setDeviceId('hollowtone-$providerId');
      client.setVersion('1.0.0');

      final userApi = client.getUserApi();
      final authResponse = await userApi.authenticateUserByName(
        authenticateUserByName: AuthenticateUserByName(
          username: provider.username,
          pw: provider.password,
        ),
      );

      final token = authResponse.data?.accessToken;
      if (token == null) {
        return null;
      }

      // Cache the token for 23 hours (tokens typically last 24 hours)
      _tokenCache[providerId] = {
        'token': token,
        'expiresAt': DateTime.now().add(const Duration(hours: 23)),
      };

      return token;
    } catch (e) {
      debugPrint('Error authenticating with provider ${provider.name}: $e');
      // Clear any cached token on authentication failure
      _tokenCache.remove(providerId);
      return null;
    }
  }

  /// Checks if a URL is a protocol URL we handle
  bool isProtocolUrl(String url) {
    try {
      final uri = Uri.parse(url);
      return isRemoteStreamScheme(uri.scheme) && uri.host == 'remote';
    } catch (e) {
      return false;
    }
  }
}

// Provider for the URL resolver
final remoteUrlResolverProvider = Provider<RemoteUrlResolver>((ref) {
  return RemoteUrlResolver(ref);
});

// Provider for the service
final remoteProviderServiceProvider = Provider<RemoteProviderService>((ref) {
  return RemoteProviderService(ref);
});
