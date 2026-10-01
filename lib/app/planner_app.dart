import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

final class PlannerApp extends StatefulWidget {
  const PlannerApp({this.taskRepository, super.key});

  final TaskRepository? taskRepository;

  @override
  State<PlannerApp> createState() => _PlannerAppState();
}

final class _PlannerAppState extends State<PlannerApp> {
  late final TaskRepository _repository;
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _repository = widget.taskRepository ?? _MemoryTaskRepository();
    _router = createPlannerRouter(
      taskService: TaskService(
        repository: _repository,
        clock: const SystemClock(),
        idGenerator: UuidIdGenerator(),
      ),
    );
  }

  @override
  void dispose() {
    _router.dispose();
    if (_repository case final _MemoryTaskRepository memory) {
      memory.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: '智能日程',
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff315b4c),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
    );
  }
}

final class _MemoryTaskRepository implements TaskRepository {
  final List<PlannerTask> _tasks = [];
  final StreamController<List<PlannerTask>> _changes =
      StreamController.broadcast();

  @override
  Future<PlannerTask?> getById(String id) async =>
      _tasks.where((task) => task.id == id).firstOrNull;

  @override
  Future<void> save(PlannerTask task) async {
    final index = _tasks.indexWhere((item) => item.id == task.id);
    if (index < 0) {
      _tasks.add(task);
    } else {
      _tasks[index] = task;
    }
    _changes.add(List.unmodifiable(_openTasks()));
  }

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield List.unmodifiable(_openTasks());
    yield* _changes.stream;
  }

  Iterable<PlannerTask> _openTasks() => _tasks.where(
    (task) =>
        task.status != TaskStatus.completed &&
        task.status != TaskStatus.cancelled &&
        task.status != TaskStatus.skipped,
  );

  Future<void> dispose() => _changes.close();
}
