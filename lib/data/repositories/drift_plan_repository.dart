import 'package:drift/drift.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';

final class DriftPlanRepository implements PlanRepository {
  DriftPlanRepository(this._database);

  final AppDatabase _database;

  @override
  Future<String?> currentPlanVersionId() async {
    final query = _database.select(_database.planVersions)
      ..where((row) => row.status.equals('confirmed'))
      ..orderBy([(row) => OrderingTerm.desc(row.createdAtUtc)])
      ..limit(1);
    return (await query.getSingleOrNull())?.id;
  }
}
