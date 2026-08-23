// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'playlist_repository.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(PlaylistRepository)
final playlistRepositoryProvider = PlaylistRepositoryProvider._();

final class PlaylistRepositoryProvider
    extends $AsyncNotifierProvider<PlaylistRepository, void> {
  PlaylistRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'playlistRepositoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$playlistRepositoryHash();

  @$internal
  @override
  PlaylistRepository create() => PlaylistRepository();
}

String _$playlistRepositoryHash() =>
    r'ce07d03d3b2b195afaff49249f88c362fe69b3d4';

abstract class _$PlaylistRepository extends $AsyncNotifier<void> {
  FutureOr<void> build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<AsyncValue<void>, void>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<AsyncValue<void>, void>,
              AsyncValue<void>,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
