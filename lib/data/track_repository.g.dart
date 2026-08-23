// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'track_repository.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(TrackRepository)
final trackRepositoryProvider = TrackRepositoryProvider._();

final class TrackRepositoryProvider
    extends $AsyncNotifierProvider<TrackRepository, void> {
  TrackRepositoryProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'trackRepositoryProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$trackRepositoryHash();

  @$internal
  @override
  TrackRepository create() => TrackRepository();
}

String _$trackRepositoryHash() => r'd2a6cda4fe8a469e3e0ed96830b8fc2bb02a2757';

abstract class _$TrackRepository extends $AsyncNotifier<void> {
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
