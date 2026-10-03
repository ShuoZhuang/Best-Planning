import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_correction_log.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_unlock_view.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class PlannerApp extends StatefulWidget {
  const PlannerApp({
    this.taskRepository,
    this.settingsRepository,
    this.scheduleSource,
    this.planningService,
    this.planApplication,
    this.planRepository,
    this.correctionLog,
    this.analytics,
    this.preferences,
    this.notifications,
    this.workspaceService,
    this.tagService,
    this.appLock,
    this.exportService,
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

  /// 剩余时长修正记录的写入端口（FR-TASK-05）。为空时修正照常生效，但不留历史，
  /// 统计也就读不到——因此生产装配必须注入。
  final TaskCorrectionLog? correctionLog;

  /// 统计查询服务。为空时"统计"页仍然可达，但会明确说明服务未装配——统计页此前
  /// 根本没有路由，是 W3 登记的缺口之一。
  final AnalyticsQuery? analytics;

  /// 学习偏好的读取与调整服务。为空时"偏好"页仍然可达，但会说明服务未装配。
  final PreferenceService? preferences;

  /// 通知端口。除了安排提醒，它还负责把"用户点击了通知"交回来（FR-NOTIFY-04 的
  /// 快捷入口）；为空时不会有任何点击来源，启动也照常。
  final NotificationPort? notifications;

  /// 领域与项目服务。为空时任务详情页不提供项目选择，其余功能不受影响。
  final WorkspaceService? workspaceService;

  /// 标签服务。为空时任务详情页不提供标签区（FR-TASK-02），统计的标签筛选也就没有
  /// 数据可筛——标签此前只有两张表，没有任何写入方（R1）。
  final TagService? tagService;

  /// 应用锁服务（需求 §11.3）。为空时不启用启动门控——即"没有应用锁"。
  ///
  /// 此前 `AppLockService.verify` 没有任何启动调用方，锁只能被开启、不会拦住任何人；
  /// 门控必须发生在启动路径上，因此由这里决定先显示解锁界面还是应用内容。
  final AppLockService? appLock;

  /// 数据导出服务（FR-DATA-06）。为空时该路由说明服务未装配。
  final ExportService? exportService;

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

  /// 启动时是否仍处于锁定状态；null 表示尚未判定完（此时显示进度，不显示内容）。
  bool? _locked;

  @override
  void initState() {
    super.initState();
    final lock = widget.appLock;
    if (lock == null) {
      _locked = false;
    } else {
      // 未装配应用锁时同步判定为"未上锁"；装配了就必须先问出来，不能默认放行。
      lock.isEnabled().then((enabled) {
        if (mounted) setState(() => _locked = enabled);
      });
    }
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
        correctionLog: widget.correctionLog,
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
      analytics: widget.analytics,
      workspaceService: widget.workspaceService,
      tagService: widget.tagService,
      appLock: widget.appLock,
      exportService: widget.exportService,
      preferences: widget.preferences,
      // 统计页若拿到当天 00:00 而不是真实时刻，会把"现在"显示成零点。
      nowUtc: clock.nowUtc(),
    );
    // FR-NOTIFY-04：点击通知后按 payload 里已经写好的去处导航。路径由本应用的写入端
    // 生成并写在 payload 中（见 `NotificationPayload`），读取端不自行拼路径，因此这里
    // 直接用；`route` 指向的任务若已被删除，详情页会明确说明而不是崩溃。
    widget.notifications?.onTapped((payload) => _router.go(payload.route));
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
    // 应用锁先于一切：锁定状态下连首次引导都不显示，否则"锁"只挡得住主界面，
    // 却把设置与引导暴露在外。
    final locked = _locked;
    if (locked == null) {
      return _shell(
        const Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    if (locked) {
      return _shell(
        AppLockUnlockView(
          service: widget.appLock!,
          onUnlocked: () => setState(() => _locked = false),
        ),
      );
    }
    return FutureBuilder<bool>(
      future: _onboardingRequired,
      builder: (context, snapshot) {
        final required = snapshot.data;
        if (required == null) {
          return _shell(
            const Scaffold(body: Center(child: CircularProgressIndicator())),
          );
        }
        // 首次启动（或引导 schema 升级）时先展示关键默认值，再进入主界面。
        // 完成状态由 onboarding schema 版本决定，因此未来新增关键默认值可以
        // 只做增量提示，而不必重复整个引导。
        if (required && !_onboardingCompleted) {
          return _shell(
            OnboardingPage(
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

  /// 非路由状态的统一外壳：引导、解锁与加载都共用同一套标题与主题。
  Widget _shell(Widget home) => MaterialApp(
    title: '智能日程',
    debugShowCheckedModeBanner: false,
    theme: _theme,
    home: home,
  );
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

  Iterable<PlannerTask> _openTasks() =>
      _tasks.where((task) => !task.status.isClosed);

  Future<void> dispose() => _changes.close();
}
