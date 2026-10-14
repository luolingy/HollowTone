import 'package:hollowtone/data/db.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'db_provider.g.dart';

@Riverpod(keepAlive: true)
AppDatabase database(Ref ref) {
  return AppDatabase();
}
