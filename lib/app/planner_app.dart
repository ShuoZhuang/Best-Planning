import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/pending_moves.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/app/router.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_correction_log.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';
import 'package:personal_planner/features/onboarding/onboarding_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_unlock_view.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class PlannerApp extends StatefulWidget {
  const PlannerApp({
    this.taskRepository,
    this.settingsRepository,
    this.appearanceFailureReporter,
    this.appearanceFallback,
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

    /// 数据备份与恢复服务（W3 最后一条缺失路由）。为空时设置入口页不显示该入口。
    this.backups,

    /// 永久清除服务（FR-DATA-04）。为空时备份页不显示该入口（不给一个点了不生效的按钮）。
    this.erasure,
    this.focusService,
    this.loadPreferenceEvidence,
    this.onSuggestionAction,

    /// 任务排程输入变化时的原因回调（FR-STAT-06 的"重排原因"来源，并驱动自动重排）。
    this.onScheduleInputChanged,

    /// 自动重排的结果流；见字段说明。
    this.replanOutcome,
    this.recovery,
    this.calendar,
    this.calendarService,
    this.academicCalendar,
    this.timetableOcr,
    this.timetableImport,
    this.timetableImagePicker,
    this.autoAdjustStore,

    /// 手动拖动产生的待处理移动（FR-CAL-05）。为空即拖动被禁用（测试与未装配排程时）。
    this.pendingMoves,
    this.zones,
    // 必填：此前默认 'Asia/Shanghai'，忘记传就会把整个应用按东八区解释用户看到的所有
    // 本地时间（作息、日界、"今天"是哪一天），而在别的时区只表现为"时间算错"、不报错。
    // 改为必填后"忘记传"是编译错误。这是 R11 的最后一块：`NotificationService` 与
    // `EventDraft` 的同类默认值此前已改必填。
    required this.timeZoneId,
    super.key,
  });

  final TaskRepository? taskRepository;
  final SettingsRepository? settingsRepository;
  final AppearanceSaveFailureReporter? appearanceFailureReporter;
  final AppearanceModeStore? appearanceFallback;

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

  /// 数据备份与恢复。为空时设置入口页不显示该入口（宁可没有，也不要点不动的入口）。
  final BackupService? backups;

  /// 永久清除服务（FR-DATA-04）。为空时备份页不显示那一块。
  final DataErasureService? erasure;

  /// 专注计时服务（FR-FOCUS）。为空时任务详情页不显示"开始专注"，`/focus/:taskId`
  /// 也会说明服务未装配。
  final FocusService? focusService;

  /// 偏好页重新分析所需的历史证据（FR-PREF-01/03）。为空时偏好页只列出已保存的建议。
  final Future<List<PreferenceEvidence>> Function()? loadPreferenceEvidence;

  /// 记录用户对偏好建议的动作（FR-STAT 的"建议采纳行为"，W5）。
  ///
  /// 为空时偏好页的一切照旧，只是统计里那一项仍为空——即改动前的状态。
  final void Function(String action, String suggestionId)? onSuggestionAction;

  /// 任务的截止日期／优先级／剩余时长／状态变化时回调一个**人类可读的原因码**。
  ///
  /// 由组合根接到统计事件日志上（`replan:` 前缀），统计页据此显示"重排原因"。为空时只是
  /// 不留原因，不影响任何行为。
  final void Function(ScheduleInputChange change)? onScheduleInputChanged;

  /// 自动重排的结果流（组合根在 `ReplanningCoordinator.onOutcome` 里写入）。
  ///
  /// 为空表示未装配自动重排，此时不弹任何提示——而不是弹一个点了没反应的提示。
  final ValueNotifier<ReplanOutcome?>? replanOutcome;

  /// 特殊日恢复服务与当日固定日程来源（Task 11）。两者缺一时该入口不显示。
  final RecoveryPlanningService? recovery;
  final CalendarRepository? calendar;

  /// 固定日程的写入服务。与只读的 [calendar] 分开注入，避免只有特殊日能读日程、
  /// 日历却没有真实的新建入口。
  final CalendarService? calendarService;

  /// 学期周数与节次模板服务。为空时设置入口不会显示该项。
  final AcademicCalendarService? academicCalendar;

  /// 本地课表识别与批次导入。四个相关依赖齐全时，日历才显示导入入口。
  final TimetableOcrEngine? timetableOcr;
  final TimetableImportService? timetableImport;
  final TimetableImagePicker? timetableImagePicker;

  /// "信任自动调整"的内存开关。为空时自建一个默认关闭的实例。
  ///
  /// 由组合根注入而不是每次自建：该值来自持久设置，此前只有打开设置页时才会被灌进来，
  /// 因此同一个设置在不同启动里表现不同（W8）。
  final AutoAdjustStore? autoAdjustStore;

  /// 手动拖动的落点（FR-CAL-05）。组合根把**同一个实例**也交给
  /// `RepositoryScheduleProblemSource`，因此这里记下的意图真的会进排程输入。
  final PendingMoveDrafts? pendingMoves;

  final TimeZoneDatabase? zones;

  /// IANA 时区标识。目前由调用方显式给出；自动识别本机时区见偏差登记 R11。
  final String timeZoneId;

  @override
  State<PlannerApp> createState() => _PlannerAppState();
}

final class _PlannerAppState extends State<PlannerApp> {
  late final TaskRepository _repository;
  late final SettingsRepository _settingsRepository;
  late final AppearanceService _appearance;
  late final Future<void> _appearanceReady;
  late final GoRouter _router;
  late final Future<bool> _onboardingRequired;
  bool _onboardingCompleted = false;

  /// 启动时是否仍处于锁定状态；null 表示尚未判定完（此时显示进度，不显示内容）。
  bool? _locked;

  /// 自动重排完成后的提示监听器（`ReplanningCoordinator.onOutcome` 写入）。
  ///
  /// **为什么提示放在这里而不是组合根**：要给出"查看调整"这个可点击的去处就得有路由，
  /// 而路由是 `PlannerApp` 建的。组合根里拿路由实例既别扭又不可测；放在这里还能用
  /// widget 测试驱动（推一个结果进去，断言提示真的出现且带入口）。
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  VoidCallback? _replanListener;

  /// 已经提示过的提案 id。连续改动会连发多次结果，同一个提案只提示一次——否则用户会看到
  /// 一串内容相同的提示，而真正**新**的那一条被淹没。
  String? _lastPromptedProposalId;

  void _onReplanOutcomeChanged() {
    final outcome = widget.replanOutcome?.value;
    if (outcome == null || !mounted) return;
    if (outcome.proposalId == _lastPromptedProposalId) return;
    _lastPromptedProposalId = outcome.proposalId;
    final messenger = _messengerKey.currentState;
    if (messenger == null) return;
    messenger.showSnackBar(
      plannerSnackBar(
        messenger,
        message: outcome.message.isEmpty ? '计划已更新' : outcome.message,
        action: outcome.applied
            ? null
            : SnackBarAction(
                label: '查看调整',
                onPressed: () =>
                    _router.go('/planning/preview/${outcome.proposalId}'),
              ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    final replanOutcome = widget.replanOutcome;
    if (replanOutcome != null) {
      _replanListener = _onReplanOutcomeChanged;
      replanOutcome.addListener(_replanListener!);
    }
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
    _appearance = AppearanceService(
      _settingsRepository,
      onSaveFailure: widget.appearanceFailureReporter,
      fallback: widget.appearanceFallback,
    )..addListener(_onAppearanceChanged);
    _appearanceReady = _appearance.load();
    _onboardingRequired = () async {
      await _appearanceReady;
      final value = await _settingsRepository.read(
        OnboardingPage.schemaVersionKey,
      );
      final stored = value == null ? null : int.tryParse(value);
      return stored == null || stored < OnboardingPage.currentSchemaVersion;
    }();
    final zones = widget.zones ?? TimeZoneDatabase();
    final clock = const SystemClock();
    final todayStartUtc = zones.localMidnightToUtc(
      _dateOnly(zones.toLocal(clock.nowUtc(), widget.timeZoneId)),
      widget.timeZoneId,
    );
    _router = createPlannerRouter(
      taskService: TaskService(
        repository: _repository,
        workspace:
            widget.workspaceService?.repository ?? _MemoryWorkspaceRepository(),
        clock: clock,
        idGenerator: UuidIdGenerator(),
        correctionLog: widget.correctionLog,
        onScheduleInputChanged: widget.onScheduleInputChanged,
      ),
      settingsService: SettingsService(repository: _settingsRepository),
      appearance: _appearance,
      scheduleSource: widget.scheduleSource ?? const EmptyScheduleViewSource(),
      // FR-CAL-05：拖动**可移动任务块**。此前这里恒为 `DisabledWeekMoveController`，
      // 于是周视图上的拖动在真实运行中永远没有反应——"拖动被禁用"不是一句说明，而是这行
      // 常量。真正生效需要一个落点（`MoveDraftSink`）与一个装配进排程输入的通道，两者都由
      // `widget.pendingMoves`（组合根构造、同时交给 `RepositoryScheduleProblemSource`）提供；
      // 未提供时（测试、或未装配排程时）退回禁用，因此不会假装拖动生效。
      moveController:
          widget.pendingMoves == null || widget.planningService == null
          ? const DisabledWeekMoveController()
          : PlanningServiceWeekMoveController(
              drafts: widget.pendingMoves!,
              planning: widget.planningService!,
            ),
      autoAdjustStore: widget.autoAdjustStore ?? MemoryAutoAdjustStore(),
      todayStartUtc: todayStartUtc,
      zones: zones,
      timeZoneId: widget.timeZoneId,
      planningService: widget.planningService,
      planApplication: widget.planApplication,
      plans: widget.planRepository,
      // 撤销（FR-REPLAN-08）只在这份仓储**同时**提供计划历史时才有入口。真实装配里
      // `DriftPlanRepository` 两者都实现；测试里只实现 `PlanRepository` 的替身则没有撤销
      // 按钮——这比"按钮在、点了却不生效"好。
      planHistory: widget.planRepository is PlanStore
          ? widget.planRepository as PlanStore
          : null,
      analytics: widget.analytics,
      workspaceService: widget.workspaceService,
      tagService: widget.tagService,
      appLock: widget.appLock,
      exportService: widget.exportService,
      backupService: widget.backups,
      erasure: widget.erasure,
      focusService: widget.focusService,
      loadPreferenceEvidence: widget.loadPreferenceEvidence,
      onSuggestionAction: widget.onSuggestionAction,
      recovery: widget.recovery,
      calendar: widget.calendar,
      calendarService: widget.calendarService,
      academicCalendar: widget.academicCalendar,
      timetableOcr: widget.timetableOcr,
      timetableImport: widget.timetableImport,
      timetableImagePicker: widget.timetableImagePicker,
      preferences: widget.preferences,
      // 统计页若拿到当天 00:00 而不是真实时刻，会把"现在"显示成零点。
      nowUtc: clock.nowUtc(),
    );
    // FR-NOTIFY-04：点击通知后按 payload 里已经写好的去处导航。路径由本应用的写入端
    // 生成并写在 payload 中（见 `NotificationPayload`），读取端不自行拼路径，因此这里
    // 直接用；`route` 指向的任务若已被删除，详情页会明确说明而不是崩溃。
    widget.notifications?.onTapped((payload) => _router.go(payload.route));
    // R8 ① 冷启动：应用是被点击通知拉起来的，那种情况平台的点击回调不会到达，必须显式
    // 读一次启动详情。导航发生在门控之下（此时界面还可能是解锁页或引导页），因此这不构成
    // 绕过应用锁的后门——锁着时先看到解锁界面，解锁后才落在通知指定的去处。
    // Windows 通知插件在 initialize() 内会同步回调 Dart。若在 initState 的
    // persistentCallbacks 阶段进入原生初始化，该回调会让渲染器在首帧尚未准备好时
    // compositeFrame，Release 随后以 0xc0000409 退出。等首帧结束后再读取启动详情，
    // 导航语义不变，但原生回调不再重入正在挂载的渲染树。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_handleLaunchPayload());
    });
  }

  Future<void> _handleLaunchPayload() async {
    final notifications = widget.notifications;
    if (notifications == null) return;
    final payload = await notifications.launchPayload();
    if (payload == null || !mounted) return;
    _router.go(payload.route);
  }

  void _onAppearanceChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    final listener = _replanListener;
    if (listener != null) widget.replanOutcome?.removeListener(listener);
    _appearance.removeListener(_onAppearanceChanged);
    _appearance.dispose();
    _router.dispose();
    if (_repository case final _MemoryTaskRepository memory) {
      memory.dispose();
    }
    super.dispose();
  }

  ThemeData get _theme => PlannerTheme.dark(glassMode: _appearance.mode);

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _appearanceReady,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return _shell(
          const Scaffold(body: Center(child: CircularProgressIndicator())),
        );
      }
      return _buildReady(context);
    },
  );

  Widget _buildReady(BuildContext context) {
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
          // 自动重排的提示要走这个 key：State 的 context 在 MaterialApp **之上**，
          // 从那里 ScaffoldMessenger.maybeOf 找不到下面这个 messenger（实测：提示不出现）。
          scaffoldMessengerKey: _messengerKey,
          routerConfig: _router,
          theme: _theme,
          builder: (context, child) =>
              PlannerBackdrop(child: child ?? const SizedBox.shrink()),
        );
      },
    );
  }

  /// 非路由状态的统一外壳：引导、解锁与加载都共用同一套标题与主题。
  Widget _shell(Widget home) => MaterialApp(
    title: '智能日程',
    debugShowCheckedModeBanner: false,
    scaffoldMessengerKey: _messengerKey,
    theme: _theme,
    builder: (context, child) =>
        PlannerBackdrop(child: child ?? const SizedBox.shrink()),
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

final class _MemoryWorkspaceRepository implements WorkspaceRepository {
  _MemoryWorkspaceRepository()
    : _areas = [
        PlannerArea(
          id: 'area-study',
          name: '学业',
          color: 0,
          sortOrder: 0,
          createdAtUtc: DateTime.utc(2026),
          updatedAtUtc: DateTime.utc(2026),
        ),
      ];

  final List<PlannerArea> _areas;
  final List<PlannerProject> _projects = [];

  @override
  Future<List<PlannerArea>> listAreas() async => List.unmodifiable(_areas);

  @override
  Future<List<PlannerProject>> listProjects() async =>
      List.unmodifiable(_projects);

  @override
  Future<void> saveArea(PlannerArea area) async {
    final index = _areas.indexWhere((item) => item.id == area.id);
    if (index < 0) {
      _areas.add(area);
    } else {
      _areas[index] = area;
    }
  }

  @override
  Future<void> saveProject(PlannerProject project) async {
    final index = _projects.indexWhere((item) => item.id == project.id);
    if (index < 0) {
      _projects.add(project);
    } else {
      _projects[index] = project;
    }
  }
}
