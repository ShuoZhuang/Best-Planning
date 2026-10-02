import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';

final class PlannerApp extends StatefulWidget {
  const PlannerApp({
    this.taskRepository,
    this.settingsRepository,
    this.scheduleSource,
    this.planningService,
    this.planApplication,
    this.planRepository,
    this.zones,
    this.timeZoneId = 'Asia/Shanghai',
    super.key,
  });

  final TaskRepository? taskRepository;
  final SettingsRepository? settingsRepository;

  /// 今日页与周视图的数据源；为空时退化为空列表（测试用）。
  final ScheduleViewSource? scheduleSource;

  /// 排程链路；为空时隐藏"生成计划"入口，预览页明确提示未装配。
  final PlanningService? planningService;
  final PlanApplicationService? planApplication;
  final PlanRepository? planRepository;

  final TimeZoneDatabase? zones;

  /// IANA 时区标识。目前由调用方显式给出；自动识别本机时区见偏差登记 R11。
  final String timeZoneId;

  @override
  State<PlannerApp> createState() => _PlannerAppState();
}

final class _PlannerAppState extends State<PlannerApp> {
  late final TaskRepository _repository;
  late final SettingsRepository _settingsRepository;
  late final GoRouter _router;
  late final Future<bool> _onboardingRequired;
  bool _onboardingCompleted = false;

  @override
  void initState() {
    super.initState();
    _repository = widget.taskRepository ?? _MemoryTaskRepository();
    _settingsRepository =
        widget.settingsRepository ?? MemorySettingsRepository();
    _onboardingRequired = _settingsRepository
        .read(OnboardingPage.schemaVersionKey)
        .then((value) {
          final stored = value == null ? null : int.tryParse(value);
          return stored == null || stored < OnboardingPage.currentSchemaVersion;
        });
    final zones = widget.zones ?? TimeZoneDatabase();
    final clock = const SystemClock();
    final todayStartUtc = zones.localMidnightToUtc(
      _dateOnly(zones.toLocal(clock.nowUtc(), widget.timeZoneId)),
      widget.timeZoneId,
    );
    _router = createPlannerRouter(
      taskService: TaskService(
        repository: _repository,
        clock: clock,
        idGenerator: UuidIdGenerator(),
      ),
      settingsService: SettingsService(repository: _settingsRepository),
      scheduleSource: widget.scheduleSource ?? const EmptyScheduleViewSource(),
      moveController: const DisabledWeekMoveController(),
      autoAdjustStore: MemoryAutoAdjustStore(),
      todayStartUtc: todayStartUtc,
      zones: zones,
      timeZoneId: widget.timeZoneId,
      planningService: widget.planningService,
      planApplication: widget.planApplication,
      plans: widget.planRepository,
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

  ThemeData get _theme => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff315b4c),
      brightness: Brightness.light,
    ),
    useMaterial3: true,
  );

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _onboardingRequired,
      builder: (context, snapshot) {
        final required = snapshot.data;
        if (required == null) {
          return MaterialApp(
            title: '智能日程',
            debugShowCheckedModeBanner: false,
            theme: _theme,
            home: const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            ),
          );
        }
        // 首次启动（或引导 schema 升级）时先展示关键默认值，再进入主界面。
        // 完成状态由 onboarding schema 版本决定，因此未来新增关键默认值可以
        // 只做增量提示，而不必重复整个引导。
        if (required && !_onboardingCompleted) {
          return MaterialApp(
            title: '智能日程',
            debugShowCheckedModeBanner: false,
            theme: _theme,
            home: OnboardingPage(
              repository: _settingsRepository,
              onComplete: () => setState(() => _onboardingCompleted = true),
            ),
          );
        }
        return MaterialApp.router(
          title: '智能日程',
          debugShowCheckedModeBanner: false,
          routerConfig: _router,
          theme: _theme,
        );
      },
    );
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

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
