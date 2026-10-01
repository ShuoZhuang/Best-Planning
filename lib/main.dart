import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:personal_planner/app/planner_app.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_task_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final database = AppDatabase.openDefault();
  runApp(
    ProviderScope(
      child: PlannerApp(taskRepository: DriftTaskRepository(database.taskDao)),
    ),
  );
}
