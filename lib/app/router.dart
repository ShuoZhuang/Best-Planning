import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:personal_planner/app/backup_assembly.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/application/academic_calendar_service.dart';
import 'package:personal_planner/application/analytics_chart_preference_service.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/application/export_service.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/pending_skips.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/plan_generation_flow.dart';
import 'package:personal_planner/application/plan_undo_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/application/recovery_planning_service.dart';
import 'package:personal_planner/application/recurring_task_service.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/week_view_preference_service.dart';
import 'package:personal_planner/application/tag_service.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/application/update_service.dart';
import 'package:personal_planner/application/window_behavior_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_glass.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/capacity_shortfall.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/recurring_task.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/task_title_lookup.dart';
import 'package:personal_planner/domain/ocr/timetable_ocr.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';
import 'package:personal_planner/features/analytics/analytics_page.dart';
import 'package:personal_planner/features/calendar/day_view/day_view_page.dart';
import 'package:personal_planner/features/calendar/event_editor/event_editor_form.dart';
import 'package:personal_planner/features/calendar/special_day/special_day_page.dart';
import 'package:personal_planner/features/calendar/schedule_item_open_target.dart';
import 'package:personal_planner/features/calendar/week_view/schedule_view_models.dart';
import 'package:personal_planner/features/calendar/week_view/week_view_page.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_controller.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_page.dart';
import 'package:personal_planner/features/focus/focus_page.dart';
import 'package:personal_planner/features/planning/plan_preview_page.dart';
import 'package:personal_planner/features/settings/app_lock/app_lock_page.dart';
import 'package:personal_planner/features/settings/academic_calendar/academic_calendar_page.dart';
import 'package:personal_planner/features/settings/appearance/appearance_page.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/features/settings/data/backup_page.dart';
import 'package:personal_planner/features/settings/window/window_background_page.dart';
import 'package:personal_planner/features/settings/data/export_page.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';
import 'package:personal_planner/features/settings/planning_rules/planning_rules_page.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';
import 'package:personal_planner/features/settings/relaxation/relaxation_page.dart';
import 'package:personal_planner/features/onboarding/onboarding_reopen_page.dart';
import 'package:personal_planner/features/settings/settings_hub_page.dart';
import 'package:personal_planner/features/settings/update/update_page.dart';
import 'package:personal_planner/features/tutorial/tutorial_page.dart';
import 'package:personal_planner/features/tasks/task_detail_page.dart';
import 'package:personal_planner/features/tasks/task_editor_page.dart';
import 'package:personal_planner/features/tasks/task_list_page.dart';
import 'package:personal_planner/features/tasks/task_type_chooser.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_detail_page.dart';
import 'package:personal_planner/features/tasks/recurring/recurring_task_editor_page.dart';
import 'package:personal_planner/features/today/today_page.dart';
import 'package:personal_planner/features/workspace/workspace_management_page.dart';
import 'package:personal_planner/scheduling/explanations.dart';
import 'package:personal_planner/scheduling/plan_differ.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';

/// 组装应用路由。
///
/// `planningService`、`planApplication` 与 `plans` 可为空：在不带数据库的测试
/// 场景下（例如只构造 `PlannerApp()`），今日页与周视图仍可显示真实数据源给出的
/// 内容，而"生成计划"入口会隐藏、调整预览会明确提示计划服务不可用，而不是
/// 显示一个点了没反应的按钮。
/// 记住"上一个由某个页面发起、且可以撤销的计划变更"（路线图 §11 Task 12）。
///
/// `PlanUndoService` 已经能撤销**整份计划**的版本（FR-REPLAN-08，用在计划预览页），
/// 而 §11 Task 12 要的是另一件事：把**刚刚那一次点击**退回去。两者的粒度不同——
/// 「完成一个任务」并不产生新的计划版本（只改任务状态），因此版本级撤销够不到它。
///
/// **为什么是一个装在闭包里的槽位，而不是 `TaskService` 上的一个方法**：可撤销的动作不只
/// 任务状态一种（跳过一次排程、改本周目标、暂停周期目标），它们分散在不同服务上；
/// 让每个服务各自记住"上一次"会把同一件事实现四遍。这里只在**装配层**记一个逆操作，
/// 由每个动作自己在发起时填进来——这也是页面只拿到"一个回调"的原因。
///
/// **只留最后一个**：这是"撤销刚刚那一下"的语义，不是历史栈。历史栈属于计划版本
/// （`PlanHistoryRepository` 已经在做），再叠一层只会让用户分不清撤销退回到哪一步。
final class _LastReversibleChange {
  Future<void> Function()? _undo;

  /// 记下一次变更的逆操作。[undo] 为空表示这次动作不可撤销（于是气泡上不出现撤销入口）。
  void remember(Future<void> Function()? undo) => _undo = undo;

  /// 执行并**清空**逆操作：同一次变更只能被撤销一次，撤完之后不该还能再撤一遍。
  Future<void> undo() async {
    final undo = _undo;
    _undo = null;
    await undo?.call();
  }

  Future<void> Function()? get current => _undo;
}

/// 打开一条事项的"详情"（M1，路线图 §3.2）。
///
/// **这是"这条事项该去哪儿"在真实装配里的唯一实现**：今日页与周视图都走它，因此同一个
/// 固定日程在两个视图里一定落同一个页面。判定本身在
/// `features/calendar/schedule_item_open_target.dart` 的纯函数里（那里可以脱离路由测试），
/// 这里只负责把目标翻译成 `go`。
///
/// [dayStartUtc] 是调用方认定的"这一天"：今日页传自己的 `day`，周视图传该条目所在的
/// **本地日**。两者都必须已经是本地 `00:00` 对应的 UTC 瞬间——换算由持有 `zones`
/// 与 `timeZoneId` 的这一层完成，纯函数不认识时区。
///
/// 解析不出目标时**什么都不做**：调用方本不该给出入口（§3.2："没有合法目标的事项不显示
/// 死入口"），这里是第二道防线，行为与 `movableTaskBlockId` 那条约定一致——不报错、
/// 不猜测，也不拿条目 id 硬拼一个路由。
void _openScheduleItemDetail(
  BuildContext context,
  ScheduleViewItem item,
  DateTime dayStartUtc,
) {
  switch (resolveScheduleItemOpenTarget(item, dayStartUtc)) {
    case TaskOpenTarget(:final taskId):
      context.go('/tasks/$taskId');
    case DayOpenTarget(:final dayStartUtc, :final eventId):
      // 日视图按 `dayStartMicros` 定位那一天；`eventId` 作为查询参数带上，
      // 让日视图能滚动/高亮到这一条（它此前只认日期）。
      context.go(
        '/calendar/day/${dayStartUtc.microsecondsSinceEpoch}'
        '?event=${Uri.encodeQueryComponent(eventId)}',
      );
    case PlanningRulesOpenTarget():
      context.go('/settings/rules');
    case null:
      break;
  }
}

/// 类型选择器的四条去向（M6，路线图 §3.3 / §11 Task 7）。
///
/// **只有"周期目标"是被注入的能力**：另外三条本来就存在（任务表单、固定日程编辑器、
/// 规划规则页），因此它们总能去；周期目标只有在装配了 `RecurringTaskService` 时才可达，
/// 而"不可达就不给卡片"这条判断写在 `TaskTypeChooserPage.isAvailable` 里。
void _openNewItemEntry(BuildContext context, PlannerNewItemKind kind) {
  switch (kind) {
    case PlannerNewItemKind.task:
      context.go('/tasks/new/task');
    case PlannerNewItemKind.recurringGoal:
      context.go('/tasks/recurring/new');
    case PlannerNewItemKind.fixedEvent:
      context.go('/calendar/new');
    case PlannerNewItemKind.protectedTime:
      context.go('/settings/rules');
  }
}

/// 周期目标详情（M6，路线图 §3.3）。
///
/// **只做导航注入**：模板、进度、历史全部由页面自己按 id 读（见
/// `RecurringTaskDetailPage.templateId` 的说明）。在这里先读一次模板再传进去，会让
/// "暂停／归档之后页面不刷新"成为一个只能靠重建整条路由才能修的问题。
Widget _recurringDetailRoute(
  BuildContext context,
  RecurringTaskService service,
  String templateId,
  DateTime nowUtc,
) => RecurringTaskDetailPage(
  service: service,
  templateId: templateId,
  nowUtc: nowUtc,
  // 「开始专注」**刻意不接**：专心路由要 `FocusService`，而这里注入一个只会跳到
  // 任务详情的按钮，等于给了一个名不副实的入口。页面在端口为空时不渲染它。
  onStartFocus: null,
  onEdit: (template) => context.go('/tasks/recurring/${template.id}/edit'),
  onDelete: (template) => context.go('/tasks'),
);

/// 处理一条容量缺口（M6，路线图 §3.4）。
///
/// 四个动作与 §3.4 列出的四条**一一对应**，而且各自落在正确的层：
/// - **调低本周目标** → `updateTemplate(..., scope: thisCycle)`：只改**这一周**的实例，
///   下周仍然按原目标重新开始。改模板会让"这周只是排不下"变成"以后都做少一点"，
///   那是用户没有要求过的改变。
/// - **放宽期望时段** → 去掉模板上的期望时段（`entireSeries`）：期望时段本来就是软约束，
///   去掉它让排程器有更多落点，而不动任何硬约束。
/// - **临时放宽每日上限** → `SettingsService.saveDateOverride`：**只影响今天**，
///   不写进长期设置。这正是"临时"两个字的落点。
/// - **允许本周不完全安排** → 不改任何东西，只回报一句说明：用户接受缺口，
///   缺口卡片因此不再出现（重新生成时那条目标仍然排不下，但这是用户已知并接受的状态）。
Future<void> _handleShortfall(
  BuildContext context, {
  required RecurringTaskService recurring,
  required SettingsService? settings,
  required TimeZoneDatabase zones,
  required String timeZoneId,
  required CapacityShortfall shortfall,
  required ShortfallAction action,

  /// 记下一次可撤销动作的逆操作（§11 Task 12）。为空时该动作不可撤销——气泡上不出现入口，
  /// 与今日页同一口径。
  void Function(Future<void> Function() undo)? onRememberUndo,
}) async {
  final template = await recurring.repository.findTemplate(
    shortfall.templateId,
  );
  if (template == null) {
    if (context.mounted) {
      showPlannerMessage(context, message: '这个周期目标已经不存在了');
    }
    return;
  }
  final now = DateTime.now().toUtc();
  // ── 记录逆操作（§11 Task 12 第 1 条）────────────────────────────────────
  //
  // 三个动作里有两个会真的改写模板：`lowerTarget` 与 `relaxPreferredWindow`。它们在改动**之前**
  // 把原值包成一个闭包记进撤销槽位，于是用户在气泡上点"撤销"能把这一步退回去。
  //
  // **只有这两条需要记**：`relaxDailyLimit` 写的是**按日例外**（`saveDateOverride`），
  // 它本身就是"只影响今天"的临时设置，撤销它要另一套按日记录的逆操作；`allowPartialWeek`
  // 什么都没改（它只是"用户接受现状"这一表态），因此无可撤销。为它们各造一个撤销入口，
  // 会让"撤销"这个词在界面上有两套含义。
  void rememberTemplateRestore(RecurringTaskTemplate before) {
    final undo = onRememberUndo;
    if (undo == null) return;
    undo(() async {
      await recurring.updateTemplate(
        before.id,
        (current) => current.copyWith(
          targetMinutes: before.targetMinutes,
          preferredStartMinute: before.preferredStartMinute,
          preferredEndMinute: before.preferredEndMinute,
        ),
        scope: RecurringEditScope.thisCycle,
        nowUtc: DateTime.now().toUtc(),
      );
    });
  }

  String message;
  switch (action) {
    case ShortfallAction.lowerTarget:
      rememberTemplateRestore(template);
      await recurring.updateTemplate(
        template.id,
        (current) => current.copyWith(
          targetMinutes: shortfall.schedulableMinutes > 0
              ? shortfall.schedulableMinutes
              : current.targetMinutes,
        ),
        scope: RecurringEditScope.thisCycle,
        nowUtc: now,
      );
      message =
          '已把「${template.title}」本周目标调低到 ${shortfall.schedulableMinutes} 分钟';
    case ShortfallAction.relaxPreferredWindow:
      rememberTemplateRestore(template);
      await recurring.updateTemplate(
        template.id,
        (current) => current.copyWith(
          preferredStartMinute: null,
          preferredEndMinute: null,
        ),
        nowUtc: now,
      );
      message = '已放宽「${template.title}」的期望时段，请重新生成计划';
    case ShortfallAction.relaxDailyLimit:
      final saveOverride = settings?.saveDateOverride;
      if (saveOverride == null) {
        if (context.mounted) {
          showPlannerMessage(context, message: '当前未装配设置服务，无法放宽每日上限');
        }
        return;
      }
      // **只对今天生效**：`PlanningRulesPatch` 的每日上限是"整窗口唯一"的字段，
      // 因此这里按今天的本地日期写一条例外，而不是把长期设置改大。
      final localToday = zones.toLocal(now, timeZoneId);
      final localDate = DateTime(
        localToday.year,
        localToday.month,
        localToday.day,
      );
      await saveOverride(
        localDate,
        PlanningRulesPatch(
          dailyMovableTaskLimitMinutes: _relaxedDailyLimit(
            template.targetMinutes,
            shortfall.shortfallMinutes,
          ),
        ),
      );
      message = '已把今天可安排的任务上限临时放宽，请重新生成计划';
    case ShortfallAction.allowPartialWeek:
      message = '已保留本周现状：不再为这个目标自动重排';
  }
  if (context.mounted) showPlannerMessage(context, message: message);
}

/// 放宽后的每日上限。
///
/// **取"模板目标"，而不是"缺口"**：缺口的单位是"整周少多少分钟"，而每日上限的单位是
/// "一天最多排多少分钟任务"。把缺口直接塞进每日上限会得到一个远小于现状的数字——那不是
/// 放宽，是收紧。用模板的周目标当一天的上限，是一个明确偏松、且与用户意图一致的取值。
int _relaxedDailyLimit(int targetMinutes, int shortfallMinutes) {
  final candidate = targetMinutes > shortfallMinutes
      ? targetMinutes
      : shortfallMinutes;
  return candidate > 0 ? candidate : 60;
}

GoRouter createPlannerRouter({
  required TaskService taskService,
  required SettingsService settingsService,
  required AppearanceService appearance,
  required ScheduleViewSource scheduleSource,
  required WeekMoveController moveController,
  required AutoAdjustStore autoAdjustStore,

  /// 「跳过本次」的落点（M4，2026-10-07 用户定义）。为 `null` 时今日页**不显示**该入口。
  PendingSkipDrafts? pendingSkips,
  required DateTime todayStartUtc,
  required TimeZoneDatabase zones,
  required String timeZoneId,
  PlanningService? planningService,
  PlanApplicationService? planApplication,
  PlanRepository? plans,

  /// 撤销（FR-REPLAN-08）用的**计划历史**端口。**单独成参而不改上面 `plans` 的类型**：
  /// 有 6 处测试替身只实现 `applyProposal`／`current`，把 `plans` 改宽会一次性牵动它们，
  /// 而"提供不了历史"本身是合法状态（那就没有撤销按钮）。
  PlanHistoryRepository? planHistory,
  AnalyticsQuery? analytics,

  /// 统计页每张卡片的图表类型选择（持久在 `analytics.chartTypes.v1`）。
  /// 为空时统计页照常可用，只是选择不跨会话保留。
  AnalyticsChartPreferenceService? chartPreferences,
  PreferenceService? preferences,
  WorkspaceService? workspaceService,

  /// 撤销**刚刚那一次**计划变更的落点（路线图 §11 Task 12）。
  ///
  /// 与 [planHistory]（整份计划的版本撤销，FR-REPLAN-08）**不是同一件事**：那个按钮在计划
  /// 预览页上，撤销的是"上一次应用的整份计划"；这里撤销的是"刚刚点的那一下"——比如完成一个
  /// 任务，而它并不产生新的计划版本，版本级撤销够不到。
  ///
  /// 由这个装配层的每个动作在发起时**填进逆操作**（见 [_LastReversibleChange]）。
  /// 为空时今日页只报消息、不显示撤销入口。
  Future<void> Function()? onUndoLastChange,
  ScheduleColorService? scheduleColors,
  WindowBehaviorService? windowBehavior,
  TagService? tagService,
  AppLockService? appLock,
  ExportService? exportService,

  /// 数据备份页（W3 最后一条缺失路由）。为空时不出现入口，也不注册路由内容。
  BackupService? backupService,
  DataErasureService? erasure,
  FocusService? focusService,
  Future<List<PreferenceEvidence>> Function()? loadPreferenceEvidence,
  void Function(String action, String suggestionId)? onSuggestionAction,
  RecoveryPlanningService? recovery,
  CalendarRepository? calendar,
  CalendarService? calendarService,
  AcademicCalendarService? academicCalendar,
  TimetableOcrEngine? timetableOcr,
  TimetableImportService? timetableImport,
  TimetableImagePicker? timetableImagePicker,
  DateTime? nowUtc,

  /// 更新检查服务（M8，路线图 §3.6 / Task 10／11）。
  ///
  /// **为空时设置入口页不显示「检查更新」**，直达 `/settings/update` 也只会说明服务未装配——
  /// 与本仓库既有的"不给一个点了才知道没装的入口"同一条约定。
  UpdateService? updateService,

  /// 周期目标的生成、结算与进度（M4～M6，路线图 §3.3）。
  ///
  /// **为空时 `/tasks/new` 不显示「周期目标」那张卡，三条周期路由也不注册**——
  /// 与本仓库既有的"不给一个点了没反应的入口"同一条约定（备份、更新、导出都是这个形状）。
  RecurringTaskService? recurringTasks,
}) {
  // §11 Task 12 的撤销槽位：每个可撤销动作在发起时把逆操作填进来，今日页拿它当撤销入口。
  final lastChange = _LastReversibleChange();
  return GoRouter(
    initialLocation: '/today',
    routes: [
      ShellRoute(
        builder: (context, state, child) => _PlannerShell(
          location: state.uri.path,
          onGeneratePlan: planningService == null
              ? null
              : (shellContext) => _generatePlan(
                  shellContext,
                  planningService,
                  planApplication,
                  autoAdjustStore,
                ),
          onSpecialDay: recovery == null || calendar == null
              ? null
              : (shellContext) => shellContext.go('/special-day'),
          child: child,
        ),
        routes: [
          GoRoute(
            path: '/today',
            builder: (context, state) => TodayPage(
              source: scheduleSource,
              day: todayStartUtc,
              toLocal: (instantUtc) => zones.toLocal(instantUtc, timeZoneId),
              nowUtc: nowUtc ?? todayStartUtc,
              // ── M4（路线图 §8）今日页的执行动作 ──────────────────────────────────
              //
              // 与 `TaskDetailPage` 同一套做法：**页面不认识路由，导航由这里注入**。
              //
              // 只接三条是因为另外两条**现在给不出诚实的落地**：
              // · 「延后」需要用户先输入延后多久（`TaskService.deferTask` 要求 `by > 0`），
              //   而 M4 的验收目标是"从今日页直接执行"，不是再造一个时长收集界面；
              // · 「请求调整」只对**已确认计划块**有意义（`movableTaskBlockId`），
              //   而这一页同时显示固定日程与保护时间——对它们给"请求调整"是假的入口。
              // 两者在端口为空时**不渲染**（页面自己保证），因此不会出现点了没反应的按钮。
              // 见 `docs/testing/m4-acceptance.md` 的未完成项。
              onStartFocus: focusService == null
                  ? null
                  : (item) => context.go('/focus/${item.taskId!}'),
              onComplete: (item) async {
                // 与任务详情页的"完成"共用同一个服务方法，因此统计记录、重排原因标签
                // 与别处完全一致——不在这一页另造一套状态变更。
                final taskId = item.taskId;
                if (taskId == null) return;
                // §11 Task 12：**先取改之前的状态再改**。「完成」不产生新的计划版本，
                // 因此版本级撤销（`PlanUndoService`）够不到它；这里记的是"把这个任务改回
                // 原来的状态"。取的是改之前那一个值，而不是写死 `open`——从别的状态回来时
                // 才不会把它错改成未完成。
                final before = await taskService.findById(taskId);
                await taskService.changeStatus(taskId, TaskStatus.completed);
                lastChange.remember(
                  before == null || before.status == TaskStatus.completed
                      ? null
                      : () => taskService.changeStatus(taskId, before.status),
                );
              },
              // M1（路线图 §3.2）：不同事项的去处由共享的解析器决定——
              // 任务进 `/tasks/:id`、固定日程进当天日视图、保护时间进 `/settings/rules`。
              // 此前这里是 `context.go('/tasks/${item.taskId!}')`：对固定日程与保护时间
              // （`taskId` 为 `null`）会当场抛 `Null check operator used on a null value`。
              onOpenDetail: (item) =>
                  _openScheduleItemDetail(context, item, todayStartUtc),
              // §11 Task 12：撤销刚刚那一次变更。装配层没接端口时不显示撤销入口
              // （今日页据此只报消息），因此这里可以无条件传。
              onUndoLastChange: lastChange.undo,
              // ── 「跳过本次」（M4，2026-10-07 用户定义）────────────────────────────
              //
              // 三步，与用户给的定义一一对应：
              //   ① 记下"这一块这次不排"（消费方是排程输入来源，见 `pending_skips.dart`）；
              //   ② 重新生成提案——**任务仍在待排集合里**，因此引擎会在截止时间前
              //      自己找下一个空档，新时间可能是今天稍后/明天/别的日期，
              //      **不是**把 `availableFromUtc` 设成明天（那是「延后到明天」）；
              //   ③ 走既有的 `PlanGenerationFlow`：默认进预览；"信任自动调整"开启时才直接应用。
              //      复用而不是新写，是为了让"默认预览、信任才自动应用"这条规则只有一处实现。
              onSkipCurrent: pendingSkips == null || planningService == null
                  ? null
                  : (item) async {
                      final blockId = movableTaskBlockId(item);
                      // 只有计划块能跳过；不可移动的条目（固定日程、保护时间）在页面上
                      // 本来就不会显示这个入口，这里是第二道防线。
                      if (blockId == null) return;
                      pendingSkips.setRequestedSkip(
                        RequestedSkip(blockId: blockId),
                      );
                      final proposal = await planningService.createProposal();
                      if (!context.mounted) return;
                      final outcome =
                          await PlanGenerationFlow(
                            isTrusted: () =>
                                autoAdjustStore.enabled &&
                                planApplication != null,
                          ).run(
                            proposal: proposal,
                            apply: planApplication == null
                                ? (proposal) async => ApplyPlanResult.stale()
                                : planApplication.apply,
                          );
                      if (!context.mounted) return;
                      if (outcome.message.isNotEmpty) {
                        showPlannerMessage(context, message: outcome.message);
                        return;
                      }
                      context.go('/planning/preview/${outcome.proposalId}');
                    },
            ),
          ),
          GoRoute(
            path: '/tasks',
            builder: (context, state) => TaskListPage(
              service: taskService,
              nowUtc: nowUtc ?? todayStartUtc,
              // §10：**当前确认计划**是"是否已安排"的唯一依据。这里把既有的 `plans`
              // 直接传下去，而不新建第二套计划服务——同一个事实只留一个出口。
              plans: plans,
              // 计划块与截止时间要显示成用户读的本地钟点；页面不认识时区，
              // 与今日页、周视图同一分工。
              zones: zones,
              timeZoneId: timeZoneId,
              // §7 的"已安排为空"空状态里的生成计划入口。未装配排程服务时不显示，
              // 免得给出一个点了没反应的按钮（与壳层"生成计划"同一判断）。
              onGeneratePlan: planningService == null
                  ? null
                  : () => _generatePlan(
                      context,
                      planningService,
                      planApplication,
                      autoAdjustStore,
                    ),
              // FR-TASK-03 的"批量调整"最后一环。整批共用同一天，因此**只换算一次**；
              // 页面不认识时区，本地日期到 UTC 的换算在此完成（与"设置截止时间"同一模式）。
              onSetDueDateForSelection: (taskIds, localDate, minute) async {
                final dueAtUtc = zones.localDateTimeToUtc(
                  localDate,
                  minute,
                  timeZoneId,
                );
                var allSaved = true;
                for (final id in taskIds) {
                  final result = await taskService.setDueDate(id, dueAtUtc);
                  allSaved = allSaved && result.isSuccess;
                }
                return allSaved;
              },
            ),
          ),
          GoRoute(
            // 通知 payload 里的 route 就指向这里（FR-NOTIFY-04 的快捷入口），
            // 此前该路由不存在，点击提醒无处可去。
            //
            // **M6（路线图 §3.3 / §11 Task 7）起这里先是类型选择器**：普通任务、周期目标、
            // 固定日程、保护时间四条去向。此前它直接就是任务表单，于是"每周英语 180 分钟"
            // 只能被当成一件 180 分钟的普通任务——而周期目标的语义（每周重新开始、按周汇总、
            // 未达标不结转）与普通任务完全不同。
            path: '/tasks/new',
            builder: (context, state) => TaskTypeChooserPage(
              onSelect: (kind) => _openNewItemEntry(context, kind),
              // **只显示真的能去的那几张卡**：某一条没有落地页时不给死入口。
              isAvailable: (kind) => switch (kind) {
                PlannerNewItemKind.task ||
                PlannerNewItemKind.fixedEvent ||
                PlannerNewItemKind.protectedTime => true,
                PlannerNewItemKind.recurringGoal => recurringTasks != null,
              },
              onCancel: () => context.go('/tasks'),
            ),
          ),
          GoRoute(
            path: '/tasks/new/task',
            builder: (context, state) => TaskEditorPage(
              service: taskService,
              settings: settingsService,
              workspace: workspaceService,
              zones: zones,
              timeZoneId: timeZoneId,
              nowUtc: nowUtc ?? todayStartUtc,
              onSaved: (task) => context.go('/tasks/${task.id}'),
              onCancel: () => context.go('/tasks/new'),
            ),
          ),
          if (recurringTasks != null) ...[
            GoRoute(
              path: '/tasks/recurring/new',
              builder: (context, state) => RecurringTaskEditorPage(
                service: recurringTasks,
                workspace: workspaceService,
                zones: zones,
                timeZoneId: timeZoneId,
                nowUtc: nowUtc ?? todayStartUtc,
                onSaved: (template) =>
                    context.go('/tasks/recurring/${template.id}'),
                onCancel: () => context.go('/tasks/new'),
              ),
            ),
            GoRoute(
              path: '/tasks/recurring/:templateId/edit',
              builder: (context, state) => RecurringTaskEditorPage(
                service: recurringTasks,
                workspace: workspaceService,
                zones: zones,
                timeZoneId: timeZoneId,
                nowUtc: nowUtc ?? todayStartUtc,
                templateId: state.pathParameters['templateId'],
                onSaved: (template) =>
                    context.go('/tasks/recurring/${template.id}'),
                onCancel: () => context.go(
                  '/tasks/recurring/${state.pathParameters['templateId']}',
                ),
              ),
            ),
            GoRoute(
              // **必须在 `/tasks/:taskId` 之前声明**：GoRouter 按声明顺序取第一个匹配，
              // 而 `/tasks/recurring/:templateId` 与 `/tasks/:taskId` 在形状上都能匹配
              // `/tasks/recurring/abc`。放到后面会让周期详情被任务详情截走。
              path: '/tasks/recurring/:templateId',
              builder: (context, state) => _recurringDetailRoute(
                context,
                recurringTasks,
                state.pathParameters['templateId'] ?? '',
                nowUtc ?? todayStartUtc,
              ),
            ),
          ],
          GoRoute(
            path: '/tasks/:taskId/edit',
            builder: (context, state) => TaskEditorPage(
              taskId: state.pathParameters['taskId'],
              service: taskService,
              settings: settingsService,
              workspace: workspaceService,
              zones: zones,
              timeZoneId: timeZoneId,
              nowUtc: nowUtc ?? todayStartUtc,
              onSaved: (task) => context.go('/tasks/${task.id}'),
              onCancel: () =>
                  context.go('/tasks/${state.pathParameters['taskId']}'),
            ),
          ),
          GoRoute(
            path: '/tasks/:taskId',
            builder: (context, state) => TaskDetailPage(
              service: taskService,
              onEdit: () =>
                  context.go('/tasks/${state.pathParameters['taskId']}/edit'),
              workspace: workspaceService,
              // FR-TASK-02 的标签入口。为空时该区不显示，其余部分照常可用。
              tags: tagService,
              // FR-FOCUS-01 的入口。页面不认识路由，导航由这里注入。
              onStartFocus: focusService == null
                  ? null
                  : () =>
                        context.go('/focus/${state.pathParameters['taskId']!}'),
              taskId: state.pathParameters['taskId']!,
              nowUtc: nowUtc ?? todayStartUtc,
              // FR-REPLAN-07 的"设置截止时间"。页面把**本地**日期与"当天第几分钟"交回，
              // 时区换算是这里的事——路由持有 `zones` 与 `timeZoneId`，页面两者都不需要。
              onSetDueDate: (localDate, minute) async {
                final result = await taskService.setDueDate(
                  state.pathParameters['taskId']!,
                  zones.localDateTimeToUtc(localDate, minute, timeZoneId),
                );
                return result.isSuccess;
              },
              // FR-REPLAN-01 的"延期事项"：把截止时间**整体后移**。页面只交回"延后多久"，目标时刻由
              // 服务层按"原截止时间 + 时长"算出——**页面因此不必知道原截止时间，也不必碰时区**
              // （与上面那条"设置截止时间"的分工正好互补）。
              //
              // 与上面刻意分成两个入口：一个是"挪到哪一天"，一个是"往后挪多久"；两者发出的领域变化
              // 类别也不同（`taskSchedulingChanged` / `taskDeferred`），统计页的"重排原因"会显示成
              // 不同的词。没有截止时间的任务**由服务层拒绝**（页面也不再显示入口）。
              onDeferTask: (by) async {
                final result = await taskService.deferTask(
                  state.pathParameters['taskId']!,
                  by: by,
                );
                return result.isSuccess;
              },
              // FR-TASK-04：任务转固定日程。**只预填标题**——事件编辑器没有"所属领域"控件，
              // 因此领域无从预填（这一点已登记，而不是假装填了）；任务本身**不动**，任务页上
              // 有对应提示，避免同一件事被排两次。
              onCreateEvent: calendarService == null
                  ? null
                  : (title) => context.go(
                      '/calendar/new?title=${Uri.encodeComponent(title)}',
                    ),
              // FR-FOCUS-05：汇总这条任务**已确认**的专注分钟，再按它重算剩余时长。
              // 汇总放在组合根——只有它能同时看到专注记录与任务服务，而两个服务彼此不必认识。
              onRecomputeFromFocus: focusService == null
                  ? null
                  : () async {
                      final taskId = state.pathParameters['taskId']!;
                      final entries = await focusService.store
                          .confirmedEntries();
                      final actualMinutes = entries
                          .where((entry) => entry.taskId == taskId)
                          .fold<int>(
                            0,
                            (sum, entry) => sum + entry.activeMinutes,
                          );
                      final result = await taskService.applyFocusRecompute(
                        taskId: taskId,
                        actualMinutes: actualMinutes,
                      );
                      return result.isSuccess;
                    },
            ),
          ),
          GoRoute(
            // 专注计时（FR-FOCUS-01）。页面早已存在，但从未有路由，也没有任何界面指向它，
            // 因此计时在真实运行中完全不可达（W3）。
            path: '/focus/:taskId',
            builder: (context, state) {
              final service = focusService;
              if (service == null) {
                return const _UnavailablePage(
                  title: '专注计时',
                  message: '专注服务未装配，暂无法计时。',
                );
              }
              return _FocusLoader(
                focus: service,
                tasks: taskService,
                taskId: state.pathParameters['taskId']!,
                // 2026-10-04 的需求：「专注中断后可以继续接续，**前提是还在待办时间段内**；超出了
                // 就要对剩余待办时间重新排序。」因此这一页需要知道该任务在**当前已确认计划**里的
                // 计划块终点。`plans` 为空（未装配计划仓储）时窗口未知——按服务里的规则，那种情况
                // 一律允许接续，因为**没有依据就别说超出了**。
                plans: plans,
              );
            },
          ),
          GoRoute(
            path: '/calendar',
            builder: (context, state) => WeekViewPage(
              source: scheduleSource,
              toLocal: (instant) => zones.toLocal(instant, timeZoneId),
              weekStart: todayStartUtc,
              moveController: moveController,
              // M5（§9）：记住本机选的「紧凑／时间轴」。
              // 与统计页图表偏好同一形状（`SettingsRepository` + 读失败回默认）。
              viewModePreference: WeekViewPreferenceService(
                settings: settingsService.repository,
              ),
              // M5（§9）＋ M1（§3.2）："点击任务、固定日程或保护时间进入对应详情"。
              //
              // 判定与今日页**共用** `_openScheduleItemDetail`：此前这一页自己判
              // `taskId != null`，而保护时间会退回日视图——那是"能进得去但进错了地方"，
              // §3.2 要求保护时间进 `/settings/rules`。固定日程仍然进日视图，
              // 但带上领域事件 id 以便定位那一条。
              onOpenItem: (item) {
                final local = zones.toLocal(item.range.startUtc, timeZoneId);
                final day = zones.localMidnightToUtc(
                  DateTime(local.year, local.month, local.day),
                  timeZoneId,
                );
                _openScheduleItemDetail(context, item, day);
              },
              onProposalCreated: (proposalId) =>
                  context.go('/planning/preview/$proposalId'),
              // FR-CAL-03 的日视图入口：与周视图互为切换，不占导航项。
              onOpenDay: (dayStartUtc) => context.go(
                '/calendar/day/${dayStartUtc.microsecondsSinceEpoch}',
              ),
              onCreateEvent: calendarService == null
                  ? null
                  : () => context.go('/calendar/new'),
              onImportTimetable:
                  timetableOcr == null ||
                      timetableImport == null ||
                      academicCalendar == null ||
                      workspaceService == null
                  ? null
                  : () => context.go('/calendar/import'),
            ),
          ),
          GoRoute(
            path: '/calendar/import',
            builder: (context, state) {
              final ocr = timetableOcr;
              final importer = timetableImport;
              final academics = academicCalendar;
              final workspace = workspaceService;
              if (ocr == null ||
                  importer == null ||
                  academics == null ||
                  workspace == null) {
                return const _UnavailablePage(
                  title: '导入课表',
                  message: '课表导入服务未完整装配，暂时无法使用。',
                );
              }
              final controller = TimetableImportController(
                ocrEngine: ocr,
                academicCalendar: academics,
                importService: importer,
                workspace: workspace,
                timeZoneId: timeZoneId,
                referenceDate: zones.toLocal(
                  nowUtc ?? todayStartUtc,
                  timeZoneId,
                ),
                imagePicker:
                    timetableImagePicker ??
                    const FileSelectorTimetableImagePicker(),
              );
              return TimetableImportPage(
                controller: controller,
                onCancel: () => context.go('/calendar'),
                onCompleted: (outcome) {
                  final messenger = ScaffoldMessenger.of(context);
                  context.go('/calendar');
                  messenger.showSnackBar(
                    plannerSnackBar(
                      messenger,
                      // 摘要里带上识别数与被跳过的原因：只报创建数会让"16 门建了 15 组"
                      // 看起来像漏了一门。
                      message: outcome.message,
                      action: SnackBarAction(
                        label: '撤销本次导入',
                        onPressed: () {
                          _undoTimetableImport(
                            messenger.context,
                            importer,
                            outcome.batch.id,
                          );
                        },
                      ),
                    ),
                  );
                },
              );
            },
          ),
          GoRoute(
            path: '/calendar/new',
            builder: (context, state) {
              final service = calendarService;
              if (service == null) {
                return const _UnavailablePage(
                  title: '新建固定日程',
                  message: '日历写入服务未装配，暂无法新建固定日程。',
                );
              }
              final localDay = zones.toLocal(todayStartUtc, timeZoneId);
              final startUtc = zones.localDateTimeToUtc(
                DateTime(localDay.year, localDay.month, localDay.day),
                9 * 60,
                timeZoneId,
              );
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '新建固定日程',
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 20),
                        EventEditorForm(
                          service: service,
                          initialStartUtc: startUtc,
                          initialEndUtc: startUtc.add(const Duration(hours: 1)),
                          timeZoneId: timeZoneId,
                          zones: zones,
                          // 领域与项目来源：固定日程也能选归属，与任务一致。
                          workspace: workspaceService,
                          // FR-TASK-04：从任务页跳来时预填标题（`?title=...`）。
                          initialTitle:
                              state.uri.queryParameters['title'] ?? '',
                          onSaved: () => context.go('/calendar'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          GoRoute(
            // 日视图（FR-CAL-03）。与周视图共用同一个数据源，只是窗口为一天。
            path: '/calendar/day/:dayStartMicros',
            builder: (context, state) {
              final micros = int.tryParse(
                state.pathParameters['dayStartMicros'] ?? '',
              );
              if (micros == null) {
                return const _UnavailablePage(
                  title: '日视图',
                  message: '日期参数无效，无法显示这一天。',
                );
              }
              return DayViewPage(
                source: scheduleSource,
                dayStartUtc: DateTime.fromMicrosecondsSinceEpoch(
                  micros,
                  isUtc: true,
                ),
                zones: zones,
                timeZoneId: timeZoneId,
                // M1（§3.2）：从今日页/周视图点一条**固定日程**进来时带上它的领域事件 id，
                // 这一页据此把那条标记出来（"定位该日程"）。为空时行为与从前一样。
                highlightEventId: state.uri.queryParameters['event'],
                onOpenWeek: () => context.go('/calendar'),
                // 调整固定日程的归属。领域清单从工作区读，页面只交回选中的 id。
                onSetEventArea: calendarService == null
                    ? null
                    : (id, areaId) => calendarService.setEventArea(
                        eventId: id,
                        areaId: areaId,
                      ),
                loadAreaOptions: workspaceService == null
                    ? null
                    : () async => [
                        for (final area in await workspaceService.listAreas())
                          ScheduleAreaOption(id: area.id, name: area.name),
                      ],
                // FR-CAL-01 的删除。页面只交回条目 id；删除端口未装配时不显示该按钮。
                // 删除后**不需要手动刷新**：日程视图由 drift 的 watch 驱动，写入会使它重新发出。
                onDeleteEvent: calendarService?.deleteEvent,
                // FR-CAL-02 的"只删这一次"。页面只交回条目 id、起点与标题；是否为重复日程、
                // 以及例外用哪个时区，都由仓储判定（它才摸得到规则行）。
                onDeleteOccurrence: calendarService == null
                    ? null
                    : (id, startUtc, title) => calendarService.deleteOccurrence(
                        anchorId: id,
                        occurrenceStartUtc: startUtc,
                        title: title,
                      ),
                onDeleteFollowing: calendarService == null
                    ? null
                    : (id, startUtc) =>
                          calendarService.deleteFollowingOccurrences(
                            anchorId: id,
                            occurrenceStartUtc: startUtc,
                          ),
                // FR-CAL-02 的"改这一次"。页面交回**本地**时刻，UTC 换算在这里做（路由持有
                // `zones` 与时区标识），与截止时间、事件编辑器两处的分工一致。
                onReplaceOccurrence: calendarService == null
                    ? null
                    : (id, startUtc, newStart, newEnd, title) =>
                          calendarService.replaceOccurrence(
                            anchorId: id,
                            occurrenceStartUtc: startUtc,
                            newStartUtc: zones.localDateTimeToUtc(
                              DateTime(
                                newStart.year,
                                newStart.month,
                                newStart.day,
                              ),
                              newStart.hour * 60 + newStart.minute,
                              timeZoneId,
                            ),
                            newEndUtc: zones.localDateTimeToUtc(
                              DateTime(newEnd.year, newEnd.month, newEnd.day),
                              newEnd.hour * 60 + newEnd.minute,
                              timeZoneId,
                            ),
                            title: title,
                          ),
                onReplaceFollowing: calendarService == null
                    ? null
                    : (id, startUtc, newStart, newEnd) =>
                          calendarService.replaceFollowingOccurrences(
                            anchorId: id,
                            occurrenceStartUtc: startUtc,
                            newStartUtc: zones.localDateTimeToUtc(
                              DateTime(
                                newStart.year,
                                newStart.month,
                                newStart.day,
                              ),
                              newStart.hour * 60 + newStart.minute,
                              timeZoneId,
                            ),
                            newEndUtc: zones.localDateTimeToUtc(
                              DateTime(newEnd.year, newEnd.month, newEnd.day),
                              newEnd.hour * 60 + newEnd.minute,
                              timeZoneId,
                            ),
                          ),
                // FR-CAL-02 的"改整个系列"：改锚点与规则本身（所有各次一起变）。
                onReplaceSeries: calendarService == null
                    ? null
                    : (id, newStart, newEnd) => calendarService.replaceSeries(
                        anchorId: id,
                        newStartUtc: zones.localDateTimeToUtc(
                          DateTime(newStart.year, newStart.month, newStart.day),
                          newStart.hour * 60 + newStart.minute,
                          timeZoneId,
                        ),
                        newEndUtc: zones.localDateTimeToUtc(
                          DateTime(newEnd.year, newEnd.month, newEnd.day),
                          newEnd.hour * 60 + newEnd.minute,
                          timeZoneId,
                        ),
                      ),
              );
            },
          ),
          GoRoute(
            // 需求的信息架构把"项目与分类管理"归在任务之下，因此它是任务的同级入口，
            // 而不是又一个设置页。管理界面本身此前完全不存在：服务层、仓库与
            // "新建项目并归属"都已就绪，但用户改不了名字、标记不了生活、归档不了项目。
            path: '/workspace',
            builder: (context, state) {
              final service = workspaceService;
              final colors = scheduleColors;
              if (service == null || colors == null) {
                return const _UnavailablePage(
                  title: '领域与项目',
                  message: '领域服务未装配，暂无法管理领域与项目。',
                );
              }
              return WorkspaceManagementPage(
                workspace: service,
                colors: colors,
              );
            },
          ),
          GoRoute(
            // 设置成为入口页：其下再列子页，导航栏因此不必每加一个设置页就长一项（W3 的
            // "信息架构提醒"）。只列出实际装配好的子页。
            path: '/settings',
            builder: (context, state) => SettingsHubPage(
              // 版本号显示在设置页底部（用户 2026-10-07 要求）。常量来源是 ackup_assembly.dart，
              // 与 pubspec.yaml 的一致性由 ersion_consistency_test 守着。
              versionLabel: appVersion,
              entries: [
                SettingsHubEntry(
                  key: const Key('settings-rules'),
                  title: '规划规则与默认值',
                  group: SettingsGroup.planning,
                  // B6：这一页里**同时**装着通知设置（`NotificationPreferencesSection`，含四类
                  // 提醒开关、提前量与免打扰时段），而原来的副标题一个字都没提通知——用户因此
                  // 在设置里找不到它（真实的反馈：按说明去找"通知设置"，翻遍设置页都没看到）。
                  // 副标题只是文案，但**入口的说明与实际内容不符就是可发现性缺陷**。
                  subtitle: '作息、精力区间、保护时间、每日上限、生活配额、通知与免打扰',
                  // M8（§12「每个入口展示一项当前关键值」，例子就是"默认专注 50 分钟"）。
                  // 读的是**已有设置**，不新建服务、不落库、不上报。
                  //
                  // **为什么要 `resolveForDate` 而不是直接读补丁**：用户规则是一层**补丁**
                  // （`PlanningRulesPatch.defaultFocusMinutes` 是可空的），真实的专注分钟数
                  // 由"默认值 ← 常见补丁 ← 工作日/周末补丁 ← 当日覆盖"逐层应用得出。
                  // 直接读补丁会在用户没改过这一项时拿到 `null`——那样入口上就什么都不显示，
                  // 而用户想问的恰恰是"现在到底是多少"。因此按**今天**解析出**生效值**。
                  currentValue: () async {
                    // 用路由器已有的 `todayStartUtc`（而不是再取一次系统时间）：
                    // 组合根已经把它算好并按本机时区落在当日零点，重算一次只会引入第二套口径。
                    final zoneNow = zones.toLocal(todayStartUtc, timeZoneId);
                    final resolved = await settingsService.resolveForDate(
                      DateTime(zoneNow.year, zoneNow.month, zoneNow.day),
                    );
                    return '默认专注 ${resolved.rules.defaultFocusMinutes} 分钟';
                  },
                  onOpen: () => context.go('/settings/rules'),
                ),
                SettingsHubEntry(
                  key: const Key('settings-appearance'),
                  title: '外观与材质',
                  group: SettingsGroup.appearance,
                  subtitle: '在无玻璃、克制、激进和极致液态玻璃之间切换',
                  // `AppearanceService` 是 `ChangeNotifier` 且启动时已 `load()` 过，
                  // 因此直接读内存里的当前值即可（不为了一个提示再查一次库）。
                  currentValue: () async =>
                      '材质：${_materialLabel(appearance.mode)}',
                  onOpen: () => context.go('/settings/appearance'),
                ),
                if (windowBehavior != null)
                  SettingsHubEntry(
                    key: const Key('settings-window'),
                    title: '窗口与后台',
                    group: SettingsGroup.appearance,
                    subtitle: '关闭窗口后收进托盘后台运行，还是直接退出程序',
                    currentValue: () async =>
                        '关闭窗口：${(await windowBehavior.load()).label}',
                    onOpen: () => context.go('/settings/window'),
                  ),
                if (academicCalendar != null)
                  SettingsHubEntry(
                    key: const Key('settings-academic-calendar'),
                    title: '学期与节次模板',
                    group: SettingsGroup.planning,
                    subtitle: '校准当前周数，设置每一节课的开始与结束时间',
                    onOpen: () => context.go('/settings/academic-calendar'),
                  ),
                SettingsHubEntry(
                  key: const Key('settings-relaxation'),
                  title: '临时放宽每日上限',
                  group: SettingsGroup.planning,
                  subtitle: '只放宽某一天的可移动任务上限，随时可以清除',
                  onOpen: () => context.go('/settings/relaxation'),
                ),
                if (preferences != null)
                  SettingsHubEntry(
                    key: const Key('settings-preferences'),
                    title: '学习偏好',
                    group: SettingsGroup.notification,
                    subtitle: '查看、确认或停用从行为中学到的偏好',
                    onOpen: () => context.go('/settings/preferences'),
                  ),
                if (appLock != null)
                  SettingsHubEntry(
                    key: const Key('settings-app-lock'),
                    title: '应用锁',
                    group: SettingsGroup.notification,
                    subtitle: '启动时需要密码；不宣称加密数据库',
                    currentValue: () async =>
                        '应用锁：${await appLock.isEnabled() ? '已开启' : '关闭'}',
                    onOpen: () => context.go('/settings/app-lock'),
                  ),
                if (exportService != null)
                  SettingsHubEntry(
                    key: const Key('settings-export'),
                    title: '数据导出',
                    group: SettingsGroup.data,
                    subtitle: '把全部事实导出为 JSON 文件',
                    onOpen: () => context.go('/settings/export'),
                  ),
                if (backupService != null)
                  SettingsHubEntry(
                    key: const Key('settings-backup'),
                    title: '数据备份与恢复',
                    group: SettingsGroup.data,
                    subtitle: '备份本地数据库，或从备份恢复（恢复在重启后生效）',
                    onOpen: () => context.go('/settings/backup'),
                  ),
                // M8（路线图 §3.6）：更新检查的入口。
                //
                // **放在「通知与隐私」这一组**：它是本应用唯一会联网的功能，用户想知道"这个程序
                // 什么时候会联网"时应该在这一组里找得到它，而不是埋在数据备份旁边。
                //
                // 入口右侧展示自动检查的开关状态（§12「每个入口展示一项当前关键值」）：用户不点
                // 进去就能看出"它到底会不会自己联网"——而这正是这一项最需要被一眼看到的信息。
                if (updateService != null)
                  SettingsHubEntry(
                    key: const ValueKey<String>('settings-update'),
                    title: '检查更新',
                    group: SettingsGroup.notification,
                    subtitle: '查看当前版本，手动检查或关闭自动检查（只请求版本信息）',
                    currentValue: () async =>
                        (await updateService.loadSettings()).autoCheckEnabled
                        ? '自动检查已开启'
                        : '自动检查已关闭',
                    onOpen: () => context.go('/settings/update'),
                  ),
                // **首次引导也要有一个"随时重看"的入口**（用户 2026-10-08 反馈后补）。
                //
                // 用户的原话："我怎么从引导首页点进去啊，这个的前提是我没有装软件吧"——
                // 他说得对：引导首页只在**首次启动**那条路径上出现，走完（或跳过）之后
                // 设置里没有任何入口能再看到它。而新手教程一直有"随时重看"，
                // **这条不一致本身就是缺口**。
                SettingsHubEntry(
                  key: const Key('settings-onboarding'),
                  title: '首次引导',
                  group: SettingsGroup.data,
                  subtitle: '重新看一遍建任务／导入课表／主要界面这三个入口',
                  onOpen: () => context.go('/settings/onboarding'),
                ),
                // 新手教程放在数据与帮助这一组的最后：它是"随时重看"的入口，
                // 不是每天要动的东西。
                SettingsHubEntry(
                  key: const Key('settings-tutorial'),
                  title: '新手教程',
                  group: SettingsGroup.data,
                  subtitle: '用真实界面截图走一遍主要功能，两分钟',
                  onOpen: () => context.go('/settings/tutorial'),
                ),
              ],
            ),
          ),
          GoRoute(
            path: '/settings/onboarding',
            // **从设置重新打开首次引导**（用户 2026-10-08 反馈后补）。
            //
            // 三个入口都**复用既有页面**，不新建第二套编辑器或导入向导——
            // 用户明确要求引导里创建的任务与普通任务**没有任何业务区别**
            // （同一任务表、同一套默认值与校验、可编辑可删除可完成可重排、
            // 统计与日历里照常显示、退出引导后仍保留）。
            builder: (context, state) => OnboardingReopenPage(
              settings: settingsService.repository,
              tasks: taskService.repository,
              onCreateTask: () => context.go('/tasks/new'),
              onImportTimetable: () => context.go('/calendar/import'),
              onLearnUi: () => context.go('/settings/tutorial'),
            ),
          ),
          GoRoute(
            path: '/settings/tutorial',
            // 从设置进来的这一次**看完不写"已看过"**：用户主动重看一遍，不该改变首次提示的状态；
            // 而首次自动弹出的那一次由 `PlannerApp` 在自己的 onComplete 里落库。
            builder: (context, state) =>
                TutorialPage(onComplete: () => context.go('/settings')),
          ),
          GoRoute(
            path: '/settings/appearance',
            builder: (context, state) => AppearancePage(service: appearance),
          ),
          GoRoute(
            path: '/settings/window',
            builder: (context, state) {
              final service = windowBehavior;
              if (service == null) {
                // 未装配时给出说明，而不是一个点了不生效的开关（与学期页同一条约定）。
                return const _UnavailablePage(
                  title: '窗口与后台',
                  message: '窗口行为服务未装配，暂无法设置关闭窗口时的行为。',
                );
              }
              return WindowBackgroundPage(windowBehavior: service);
            },
          ),
          GoRoute(
            path: '/settings/academic-calendar',
            builder: (context, state) {
              final service = academicCalendar;
              if (service == null) {
                return const _UnavailablePage(
                  title: '学期与节次模板',
                  message: '学期服务未装配，暂无法保存学期与节次模板。',
                );
              }
              return AcademicCalendarPage(
                service: service,
                referenceDate: zones.toLocal(todayStartUtc, timeZoneId),
                timeZoneId: timeZoneId,
              );
            },
          ),
          GoRoute(
            // FR-REPLAN-07 的"临时放宽每日上限"处理入口。此前**这条入口完全不存在**：
            // `saveDateOverride` 是既有的写入方法，但全库**没有任何调用方**，
            // 因此"临时例外"这一层从来没有被用户碰过。
            //
            // 入口放在设置里而不是只挂在"无可行计划"报告上：需求只要求"提供处理入口"，
            // 而用户想在计划变得不可行**之前**主动腾出时间也是合理的（例如知道今晚要加班）。
            path: '/settings/relaxation',
            builder: (context, state) {
              // `todayStartUtc` 就是"今天本地零点"，因此它的本地日历日就是今天——
              // 不必再向路由器引入一个时钟（那会让"今天"有两个来源）。
              final today = zones.toLocal(todayStartUtc, timeZoneId);
              final localDate = DateTime(today.year, today.month, today.day);
              Future<int> effectiveLimit() async =>
                  (await settingsService.resolveForDate(localDate))
                      .rules
                      .dailyMovableTaskLimitMinutes;
              Future<int?> overrideMinutes() async =>
                  (await settingsService.loadDateOverride(localDate))
                      ?.dailyMovableTaskLimitMinutes;
              return RelaxationPage(
                localDate: localDate,
                loadEffectiveLimitMinutes: effectiveLimit,
                loadOverrideMinutes: overrideMinutes,
                onSave: (minutes) async {
                  // 例外的**全部**内容就是"这一天把上限改成多少"。用 patch 而不是复制整份
                  // 规则：复制整份会让今天之后任何规则改动都和这条例外脱节。
                  await settingsService.saveDateOverride(
                    localDate,
                    PlanningRulesPatch(dailyMovableTaskLimitMinutes: minutes),
                  );
                  return true;
                },
                onClear: () async {
                  await settingsService.clearDateOverride(localDate);
                  return true;
                },
              );
            },
          ),
          GoRoute(
            path: '/settings/backup',
            builder: (context, state) {
              final service = backupService;
              if (service == null) {
                return const _UnavailablePage(
                  title: '数据备份与恢复',
                  message: '备份服务未装配，暂无法备份或恢复。',
                );
              }
              // 文件选择与归档写入用的是同一个端口实例（与导出页同样的做法）。
              //
              // **永久清除的入口现在是接通的**（spec §18 第 18 项此前因此未勾选）。原先不传
              // `erasure` 是因为"删库需要关库—换实例—重开"；现改为**延迟到下次启动执行**
              // （与恢复那条路径同一个套路，见 `backup_assembly.dart`），因此不需要在运行中
              // 换库实例。`erasure` 为空时（测试或未装配）那一块仍然不渲染——不给一个点了
              // 不生效的按钮。
              return BackupPage(
                backups: service,
                erasure: erasure,
                files: const FileSelectorAdapter(),
              );
            },
          ),
          GoRoute(
            path: '/settings/rules',
            builder: (context, state) => PlanningRulesPage(
              service: settingsService,
              autoAdjustStore: autoAdjustStore,
            ),
          ),
          GoRoute(
            // M8（路线图 §3.6 / Task 11）：更新设置页。
            //
            // 未装配时给出说明而不是空白页：深链接（通知 payload、用户手改地址）可能直接落在这里。
            path: '/settings/update',
            builder: (context, state) {
              final service = updateService;
              if (service == null) {
                return const _UnavailablePage(
                  title: '检查更新',
                  message: '更新服务未装配，暂无法检查更新。',
                );
              }
              return UpdatePage(
                // **控制器在这里建、在这里交给页面**：页面只认 `UpdatePageController`
                // （见 `update_page.dart` 的说明），因此六种状态都能脱离真服务测试。
                //
                // 每进入一次新建一个：控制器是有状态的（上次结论、最后一次是谁触发的），
                // 复用同一个实例会让"上一次的失败原因"出现在这一次的页面上。既然是在这里 new 的，
                // 释放也交给页面（`disposeController`）——这一层没有别的持有者。
                controller: ServiceUpdatePageController.production(service),
                disposeController: true,
              );
            },
          ),
          GoRoute(
            // 应用锁必须可达，否则它只能"被开启"却无法被开启：启动门控已经存在，但设置
            // 密码的入口此前没有任何路由，用户永远无法让锁生效（W6 + W3）。
            path: '/settings/app-lock',
            builder: (context, state) {
              final service = appLock;
              if (service == null) {
                return const _UnavailablePage(
                  title: '应用锁',
                  message: '应用锁服务未装配，暂无法开启或关闭应用锁。',
                );
              }
              return AppLockPage(service: service);
            },
          ),
          GoRoute(
            // 数据导出（FR-DATA-06）。服务与适配器早已写好并有测试，但从未在生产装配，
            // 因此"导出"在真实运行中不可达。
            path: '/settings/export',
            builder: (context, state) {
              final service = exportService;
              if (service == null) {
                return const _UnavailablePage(
                  title: '数据导出',
                  message: '导出服务未装配，暂无法导出数据。',
                );
              }
              // 目录选择与写入用的是同一个端口实例，这里直接复用服务里那一份。
              return ExportPage(service: service);
            },
          ),
          GoRoute(
            path: '/analytics',
            builder: (context, state) {
              final query = analytics;
              // 与调整预览一致：依赖未装配时明确说明原因，而不是给一个点了没反应的页面。
              if (query == null) {
                return const _UnavailablePage(
                  title: '统计',
                  message: '统计服务未装配，暂无法展示统计报表。',
                );
              }
              return AnalyticsPage(
                analytics: query,
                nowUtc: nowUtc ?? todayStartUtc,
                // 必填：统计的"今天／本周／本月"必须是用户本机时区的日界（§13／R11）。
                // 路由器本来就持有这两样，因此这里只是把已有的东西交下去。
                zones: zones,
                timeZoneId: timeZoneId,
                // FR-STAT-02 的标签筛选。标签服务未装配时整块不渲染。
                loadTagNames: tagService?.allTagNames,
                // 图表类型选择（用户要求"由我来选择显示哪个"）。设置仓储未装配时
                // 选择只在本次会话内生效，而不是让整页不可用。
                loadChartKinds: chartPreferences?.load,
                saveChartKind: chartPreferences?.save,
                // 空状态的下一步动作（§11 Task 12 Step 3）。两个端口都只在对应服务装配时传，
                // 页面据此决定是否渲染按钮——给一个点了没反应的入口比没有入口更糟。
                onGeneratePlan: planningService == null
                    ? null
                    : () => _generatePlan(
                        context,
                        planningService,
                        planApplication,
                        autoAdjustStore,
                      ),
                onOpenRestRules: () => context.go('/settings/rules'),
              );
            },
          ),
          GoRoute(
            // 设置类页面统一挂在 /settings 之下，入口页按前缀判断导航选中项。
            path: '/settings/preferences',
            builder: (context, state) {
              final service = preferences;
              if (service == null) {
                return const _UnavailablePage(
                  title: '偏好设置',
                  message: '偏好服务未装配，暂无法查看或调整学习到的偏好。',
                );
              }
              return PreferencesPage(
                service: service,
                // FR-PREF-01/03 的输入端：没有它，这一页永远列不出建议。
                loadEvidence: loadPreferenceEvidence,
                // FR-STAT 的"建议采纳行为"来源（W5）。
                onSuggestionAction: onSuggestionAction,
              );
            },
          ),
          GoRoute(
            // 特殊日与次日恢复保护（Task 11）。C8 修复后恢复例外不再落库，因此这条链路
            // 必须真正可达：页面早已存在，却从来没有路由，也没有任何界面指向它（W3）。
            path: '/special-day',
            builder: (context, state) {
              final service = recovery;
              final events = calendar;
              if (service == null || events == null) {
                return const _UnavailablePage(
                  title: '特殊日与恢复保护',
                  message: '恢复服务未装配，暂无法生成恢复方案。',
                );
              }
              return _SpecialDayLoader(
                recovery: service,
                calendar: events,
                settings: settingsService,
                zones: zones,
                timeZoneId: timeZoneId,
                nowUtc: nowUtc ?? todayStartUtc,
                onOpenPreview: (proposalId) =>
                    context.go('/planning/preview/$proposalId'),
              );
            },
          ),
          GoRoute(
            path: '/planning/preview/:proposalId',
            builder: (context, state) => _PlanPreviewLoader(
              // **key 是必需的，不是装饰**：`_PlanPreviewLoaderState` 用
              // `late final Future<PlanPreviewModel> _model = _build()` 只算一次。重新生成
              // （见页面里的"重新生成计划"）会 `go` 到**同一路由的不同 proposalId**，此时
              // widget 类型与位置都没变，Flutter 会**复用 State**，`_build()` 不会重跑——页面
              // 会继续显示那份已经过期的模型，按钮看起来点了没反应。按 proposalId 给 key 会让
              // 参数变化时换掉 Element，从而重建 State。
              key: ValueKey(state.pathParameters['proposalId']),
              proposalId: state.pathParameters['proposalId']!,
              planning: planningService,
              application: planApplication,
              plans: plans,
              planHistory: planHistory,
              taskTitles: taskService,
              onRememberUndo: lastChange.remember,
              // M6（§3.4）：缺口卡片的四个动作需要周期服务（改模板、放宽期望时段）与
              // 设置服务（临时放宽每日上限）。
              recurring: recurringTasks,
              settings: settingsService,
              autoAdjustStore: autoAdjustStore,
              zones: zones,
              timeZoneId: timeZoneId,
            ),
          ),
        ],
      ),
    ],
  );
}

/// 特殊日页需要**当日的规则与固定日程**，因此先把它们装配好再渲染页面。
///
/// 这正是 W3 里说的"特殊日需要动态数据装配"：页面本身只接收已经解析好的规则与事件，
/// 因为它不该知道规则来自设置、事件来自日历仓库。
final class _SpecialDayLoader extends StatelessWidget {
  const _SpecialDayLoader({
    required this.recovery,
    required this.calendar,
    required this.settings,
    required this.zones,
    required this.timeZoneId,
    required this.nowUtc,
    required this.onOpenPreview,
  });

  final RecoveryPlanningService recovery;
  final CalendarRepository calendar;
  final SettingsService settings;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final DateTime nowUtc;
  final ValueChanged<String> onOpenPreview;

  @override
  Widget build(BuildContext context) => FutureBuilder<_SpecialDayInputs>(
    future: _load(),
    builder: (context, snapshot) {
      final inputs = snapshot.data;
      if (inputs == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return SpecialDayPage(
        recoveryDate: inputs.recoveryDate,
        rules: inputs.rules,
        fixedEvents: inputs.fixedEvents,
        timeZoneId: timeZoneId,
        onCreateOverride: recovery.createOverride,
        onOpenPreview: onOpenPreview,
      );
    },
  );

  Future<_SpecialDayInputs> _load() async {
    // "恢复日"取本机今天：用户是在当晚或次日处理"晚归"的。选择其它日期需要日期选择器，
    // 那属于界面功能，不在本轮范围内，因此这里只用今天而不是假装支持任意日期。
    final local = zones.toLocal(nowUtc, timeZoneId);
    final today = DateTime(local.year, local.month, local.day);
    final startUtc = zones.localMidnightToUtc(today, timeZoneId);
    final endUtc = zones.localMidnightToUtc(
      today.add(const Duration(days: 1)),
      timeZoneId,
    );
    final rules = (await settings.resolveForDate(today)).rules;
    // 早课之类的固定日程会与"最低睡眠"冲突（FR-RECOVERY-04），因此必须带上当日实际事件。
    final events = await calendar.occurrencesBetween(startUtc, endUtc);
    return _SpecialDayInputs(
      recoveryDate: today,
      rules: rules,
      fixedEvents: events,
    );
  }
}

final class _SpecialDayInputs {
  const _SpecialDayInputs({
    required this.recoveryDate,
    required this.rules,
    required this.fixedEvents,
  });

  final DateTime recoveryDate;
  final PlanningRules rules;
  final List<CalendarOccurrence> fixedEvents;
}

/// 专注页需要"任务身份"（标题），因此这里先把任务读出来再渲染页面。
///
/// 任务不存在时给出明确说明而不是一个空标题：通知 payload 的 `route` 也会指向任务，
/// 而任务可能已被永久清除，此时用户需要知道发生了什么。
final class _FocusLoader extends StatefulWidget {
  const _FocusLoader({
    required this.focus,
    required this.tasks,
    required this.taskId,
    this.plans,
  });

  final FocusService focus;
  final TaskService tasks;
  final String taskId;

  /// 当前已确认计划，用来判断"接续是否已超出计划时段"。为空时窗口未知。
  final PlanRepository? plans;

  @override
  State<_FocusLoader> createState() => _FocusLoaderState();
}

final class _FocusLoaderState extends State<_FocusLoader> {
  late final Future<_FocusData> _data = _load();

  Future<_FocusData> _load() async => _FocusData(
    task: await widget.tasks.findById(widget.taskId),
    plannedEndUtc: await _plannedEnd(),
  );

  /// 该任务在当前已确认计划里的**计划块终点**；没有计划、或该任务没有块时为 null。
  ///
  /// 取**最早**那一块：一个任务可能被拆成多段，而"待办时间段"在用户心里就是眼下这一段；用最早
  /// 那块判断"是否超出"最保守——不会因为后面还排了一段就以为时间还多。
  Future<DateTime?> _plannedEnd() async {
    final plan = await widget.plans?.current();
    if (plan == null) return null;
    final blocks = plan.blocks.where((b) => b.taskId == widget.taskId).toList()
      ..sort((a, b) => a.range.startUtc.compareTo(b.range.startUtc));
    return blocks.isEmpty ? null : blocks.first.range.endUtc;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_FocusData>(
    future: _data,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      final data = snapshot.data;
      final task = data?.task;
      if (task == null) {
        return const _UnavailablePage(
          title: '专注计时',
          message: '该任务不存在或已被永久删除，无法计时。',
        );
      }
      return FocusPage(
        service: widget.focus,
        taskId: task.id,
        taskTitle: task.title,
        plannedEndUtc: data?.plannedEndUtc,
      );
    },
  );
}

final class _FocusData {
  const _FocusData({required this.task, required this.plannedEndUtc});

  final PlannerTask? task;
  final DateTime? plannedEndUtc;
}

Future<void> _generatePlan(
  BuildContext context,
  PlanningService planning,
  PlanApplicationService? application,
  AutoAdjustStore autoAdjustStore,
) async {
  final proposal = await planning.createProposal();
  if (!context.mounted) return;

  // FR-REPLAN-03/04：默认只打开预览等确认；"信任自动调整"开启时**直接应用**，而历史与原因
  // 仍会写入（应用本身会落新计划版本与变更日志），因此"开启后仍记录"不是额外要做的事。
  // 分支抽在 `PlanGenerationFlow` 里，那段逻辑因此有测试——路由在本仓库从不被测试覆盖。
  final outcome =
      await PlanGenerationFlow(
        // 未装配应用服务时**不自动应用**：宁可回落到"去预览确认"，也不假装应用了。
        isTrusted: () => autoAdjustStore.enabled && application != null,
      ).run(
        proposal: proposal,
        // 不可达的兜底：`application == null` 时上面的 isTrusted 为 false，apply 不会被调用。
        apply: application == null
            ? (proposal) async => ApplyPlanResult.stale()
            : application.apply,
      );
  if (!context.mounted) return;
  if (outcome.message.isNotEmpty) {
    showPlannerMessage(context, message: outcome.message);
  }
  context.go('/planning/preview/${proposal.proposalId}');
}

final class _PlannerShell extends StatelessWidget {
  const _PlannerShell({
    required this.location,
    required this.child,
    this.onGeneratePlan,
    this.onSpecialDay,
  });

  final String location;
  final Widget child;
  final Future<void> Function(BuildContext context)? onGeneratePlan;

  /// 特殊日与恢复保护的入口。为空时不显示该动作——未装配恢复服务时不留死按钮。
  final void Function(BuildContext context)? onSpecialDay;

  static const _topLevelLocations = <String>{
    '/today',
    '/tasks',
    '/workspace',
    '/calendar',
    '/analytics',
    '/settings',
  };

  bool get _showsBackButton => !_topLevelLocations.contains(location);

  String get _parentLocation {
    if (location.startsWith('/focus/')) {
      final segments = Uri.tryParse(location)?.pathSegments;
      final taskId = segments == null || segments.isEmpty
          ? null
          : segments.last;
      return taskId == null ? '/tasks' : '/tasks/$taskId';
    }
    if (location.startsWith('/tasks/')) return '/tasks';
    if (location.startsWith('/calendar/')) return '/calendar';
    if (location.startsWith('/settings/')) return '/settings';
    if (location == '/special-day') return '/today';
    if (location.startsWith('/planning/preview/')) return '/calendar';
    return '/today';
  }

  int get _selectedIndex => switch (location) {
    '/tasks' => 1,
    '/workspace' => 2,
    // 周视图与日视图同属"日历"，因此按前缀判断而不是逐条列举。
    final path when path.startsWith('/calendar') => 3,
    '/analytics' => 4,
    // 设置类页面都归在"设置"这一项下，因此按前缀判断而不是逐条列举。
    final path when path.startsWith('/settings') => 5,
    _ => 0,
  };

  @override
  Widget build(BuildContext context) {
    final generate = onGeneratePlan;
    final specialDay = onSpecialDay;
    final body = Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        flexibleSpace: const PlannerGlassChrome(child: SizedBox.expand()),
        automaticallyImplyLeading: false,
        leading: _showsBackButton
            ? IconButton(
                key: const Key('shell-back-button'),
                tooltip: '返回',
                onPressed: () => context.go(_parentLocation),
                icon: const Icon(Icons.arrow_back_rounded),
              )
            : null,
        titleSpacing: _showsBackButton ? 4 : 20,
        toolbarHeight: 68,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BrandMark(),
            SizedBox(width: 12),
            Text(
              '智能日程',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        actions: [
          if (specialDay != null)
            TextButton.icon(
              key: const Key('open-special-day'),
              onPressed: () => specialDay(context),
              icon: const Icon(Icons.bedtime_outlined),
              label: const Text('特殊日'),
            ),
          if (generate != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: FilledButton.icon(
                onPressed: () => generate(context),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('生成计划'),
              ),
            ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          PlannerGlassChrome(
            child: NavigationRail(
              extended: true,
              selectedIndex: _selectedIndex,
              onDestinationSelected: (index) {
                context.go(switch (index) {
                  1 => '/tasks',
                  2 => '/workspace',
                  3 => '/calendar',
                  4 => '/analytics',
                  5 => '/settings',
                  _ => '/today',
                });
              },
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.today_outlined),
                  selectedIcon: _SelectedNavIcon(Icons.today),
                  label: Text('今日'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.checklist_outlined),
                  selectedIcon: _SelectedNavIcon(Icons.checklist),
                  label: Text('任务'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.account_tree_outlined),
                  selectedIcon: _SelectedNavIcon(Icons.account_tree),
                  label: Text('领域'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.calendar_view_week_outlined),
                  selectedIcon: _SelectedNavIcon(Icons.calendar_view_week),
                  label: Text('日历'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.insights_outlined),
                  selectedIcon: _SelectedNavIcon(Icons.insights),
                  label: Text('统计'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune_outlined),
                  selectedIcon: _SelectedNavIcon(Icons.tune),
                  label: Text('设置'),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );

    // **Esc 返回上一级**（路线图 §6 强制测试第 2 条："Esc 能关闭对话框或返回上一级"）。
    //
    // 此前**全库没有任何 Esc 处理**：返回只能靠点左上角那个按钮，键盘用户没有对应按键。
    // 这里只在**本来就有返回按钮的页面**上接管 Esc（`_showsBackButton`），因此：
    // - 顶层页面（今日／任务／日历…）不受影响，Esc 不会把用户莫名其妙地弹回今日；
    // - 弹窗类（对话框）自带 Esc 处理，它们的路由在对话框层，不受这里影响。
    //
    // 用 `Shortcuts` + `Actions` 而不是硬编码 `onKeyEvent`：这样它进入标准动作体系，
    // 焦点在哪个子控件上都能拿到（`Focus` 会沿着树上冒到最近的 `Shortcuts`）。
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        if (_showsBackButton)
          const SingleActivator(LogicalKeyboardKey.escape):
              const _ShellBackIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ShellBackIntent: CallbackAction<_ShellBackIntent>(
            onInvoke: (_) {
              context.go(_parentLocation);
              return null;
            },
          ),
        },
        child: body,
      ),
    );
  }
}

/// "返回上一级"的意图，只由 [_PlannerShell] 的 Esc 快捷键产生。
final class _ShellBackIntent extends Intent {
  const _ShellBackIntent();
}

final class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) => Container(
    width: 34,
    height: 34,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      borderRadius: BorderRadius.circular(9),
    ),
    alignment: Alignment.center,
    child: const Icon(Icons.view_timeline_outlined, size: 20),
  );
}

final class _SelectedNavIcon extends StatelessWidget {
  const _SelectedNavIcon(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 3,
        height: 20,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Icon(icon),
    ],
  );
}

/// 依赖未装配时的占位页。
///
/// 明确写出"哪个服务没装、因此什么做不到"，而不是渲染一个空页面或点了没反应的
/// 控件——后者会让人以为功能坏了，而不是"这次没接线"。
final class _UnavailablePage extends StatelessWidget {
  const _UnavailablePage({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

/// 从内存中的提案构建真实的调整预览：与当前已确认计划做差异、带上冲突与缺口，
/// 确认时调用 `PlanApplicationService` 真正落库。
final class _PlanPreviewLoader extends StatefulWidget {
  const _PlanPreviewLoader({
    required this.proposalId,
    required this.autoAdjustStore,
    required this.zones,
    required this.timeZoneId,
    this.planning,
    this.application,
    this.plans,
    this.planHistory,
    this.recurring,
    this.settings,
    this.taskTitles,
    this.onRememberUndo,
    super.key,
  });

  /// 标题查询端口（Task 12A Step 6）。为空时预览回落到"未命名任务"——
  /// **绝不回落成裸 UUID**。
  final TaskTitleLookup? taskTitles;

  /// 记下一次可撤销动作的逆操作（§11 Task 12 第 1 条）。
  ///
  /// 缺口卡片里的「调低本周目标」与「放宽期望时段」会真的改写模板，因此要把改动前的值记下来。
  /// 为空时那两个动作不可撤销——气泡上不出现撤销入口，与今日页同一口径。
  final void Function(Future<void> Function() undo)? onRememberUndo;

  final String proposalId;
  final AutoAdjustStore autoAdjustStore;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final PlanningService? planning;
  final PlanApplicationService? application;
  final PlanRepository? plans;
  final PlanHistoryRepository? planHistory;

  /// 周期目标（M6）：缺口卡片据此改模板、放宽期望时段与写入"临时放宽每日上限"。
  final RecurringTaskService? recurring;

  /// 与设置页共用同一个服务（"临时放宽每日上限"是**设置**，不在这里另造一份）。
  final SettingsService? settings;

  @override
  State<_PlanPreviewLoader> createState() => _PlanPreviewLoaderState();
}

final class _PlanPreviewLoaderState extends State<_PlanPreviewLoader> {
  late final Future<PlanPreviewModel> _model = _build();

  Future<PlanPreviewModel> _build() async {
    final planning = widget.planning;
    if (planning == null) {
      return PlanPreviewModel(
        proposalId: widget.proposalId,
        changes: const [],
        conflicts: const ['当前未装配排程服务，无法生成或应用计划'],
        isStale: true,
      );
    }
    final proposal = planning.preview(widget.proposalId);
    if (proposal == null) {
      // 提案只保存在内存中；重启或重新生成后旧链接会失效。
      return PlanPreviewModel(
        proposalId: widget.proposalId,
        changes: const [],
        conflicts: const ['该调整提案已失效，请重新生成计划'],
        isStale: true,
      );
    }

    final current = await widget.plans?.current();
    final diff = const PlanDiffer().diff(
      current?.blocks ?? const <PlannedBlock>[],
      proposal.blocks,
    );
    // M6（§3.4）：容量缺口。**与提案来自同一次生成**，因此这里不重新排程，只把"排不下的
    // 那些周期目标"翻译成用户能读懂、能处置的一条缺口。
    final shortfalls = await planning.shortfallsFor(proposal);
    // ── 标题与结构化原因（Task 12A Step 6）──────────────────────────────────
    //
    // **标题由这一层查，不放进 `UnscheduledTask`**：引擎的东西以 id 为准，标题可能被用户随时
    // 改；固化进引擎输出就成了一份旧快照。查不到时回落到"未命名任务"，**绝不显示裸 UUID**。
    final lookup = widget.taskTitles;
    final displayInfos = lookup == null
        ? const <TaskDisplayInfo>[]
        : await resolveTaskDisplayInfos(lookup, [
            for (final task in proposal.unscheduled) task.taskId,
          ]);
    final titleByTaskId = {
      for (final info in displayInfos) info.taskId: info.title,
    };
    String titleOf(String taskId) => titleByTaskId[taskId] ?? unnamedTaskLabel;

    return PlanPreviewModel(
      proposalId: widget.proposalId,
      changes: [
        for (final change in diff.changes)
          PreviewChange(
            kind: _kindOf(change),
            title: _titleOf(widget.zones, widget.timeZoneId, change),
            reason: explanationLabel(change.reason ?? ''),
            // M4（§8）：预览必须显示**原时间与目标时间**，否则用户看不出"从哪挪到哪"。
            // 空的那一侧留 `null`：新增没有原时间、未安排没有目标时间。
            fromLabel: _timeLabelOf(
              widget.zones,
              widget.timeZoneId,
              change.before,
            ),
            toLabel: _timeLabelOf(
              widget.zones,
              widget.timeZoneId,
              change.after,
            ),
          ),
        // §8 的「未安排」是**独立一类**：提案没排下的任务不在 `diff.changes` 里
        // （diff 只比较两侧都有的计划块），因此必须单独取 `proposal.unscheduled`。
        //
        // 文案按 Task 12A Step 6 第 5 条：主行是「标题 + 还缺多少分钟」，`reason` 是引擎给的
        // **结构化主原因**翻成的一句人话。此前这里写的是 `'${task.taskId} 还缺 …'` 加一句
        // 笼统的"可用时间不足"——用户看到一串 UUID，也不知道该改什么。
        for (final task in proposal.unscheduled)
          PreviewChange(
            kind: PreviewChangeKind.unplanned,
            title: '${titleOf(task.taskId)} 还缺 ${task.shortageMinutes} 分钟',
            reason: unscheduledReasonLabel(task.primaryReason),
          ),
      ],
      conflicts: [
        for (final conflict in proposal.conflicts) conflictLabel(conflict.code),
        // 冲突那一组也带上标题：同一条缺口在两组里出现时，两处必须叫同一个名字，
        // 否则用户会以为是两件事。
        for (final task in proposal.unscheduled)
          '「${titleOf(task.taskId)}」还缺 ${task.shortageMinutes} 分钟',
      ],
      isStale: false,
      shortfalls: shortfalls,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PlanPreviewModel>(
    future: _model,
    builder: (context, snapshot) {
      final model = snapshot.data;
      if (model == null) {
        return const Center(child: CircularProgressIndicator());
      }
      return PlanPreviewPage(
        model: model,
        autoAdjustStore: widget.autoAdjustStore,
        onConfirm: () => _confirm(context, model),
        // M6（§3.4）：缺口的四个处理动作。**为空时四个按钮都不渲染**——没装配周期服务
        // 就没有"调低本周目标"可改，给出按钮等于给一个点了没反应的入口。
        onHandleShortfall: widget.recurring == null
            ? null
            : (shortfall, action) => _handleShortfall(
                context,
                recurring: widget.recurring!,
                settings: widget.settings,
                zones: widget.zones,
                timeZoneId: widget.timeZoneId,
                shortfall: shortfall,
                action: action,
                onRememberUndo: widget.onRememberUndo,
              ),
        // 时序图 `else stale` 分支的 `request recalculation`：复用顶层的 `_generatePlan`
        // ——它已经是"生成提案 → 按信任设置决定是否直接应用 → 导航到预览"的既有路径，因此这里
        // 不另写一套。未装配排程服务时传 null，页面据此不显示按钮（那种情况下根本无法重新生成）。
        onRecalculate: widget.planning == null
            ? null
            : () => _generatePlan(
                context,
                widget.planning!,
                widget.application,
                widget.autoAdjustStore,
              ),
        // FR-REPLAN-08 的撤销入口。`PlanUndoService` 是**无状态**的薄服务，因此就地构造，
        // 不再穿一条 main→PlannerApp→router 的参数链（那要多 4 处装配）。
        onUndoPlan: widget.planHistory == null
            ? null
            : () async {
                try {
                  await PlanUndoService(
                    repository: widget.planHistory!,
                    // B5：撤销同样改变"当前计划"，因此要让提醒重新同步，否则撤销之后提醒还停在
                    // 被撤销的那一版上。**复用 `application` 上那同一个回调**，而不是再穿一条
                    // main→PlannerApp→router 的参数链——上一行注释就是这条先例（那要多 4 处装配），
                    // 而且两处要做的本来就是同一件事。
                    onPlanChanged: widget.application?.onPlanChanged,
                  ).undoLastAppliedPlan();
                  return true;
                } on StateError {
                  // 没有当前或上一版计划：这是"无可撤销"，不是故障。
                  return false;
                }
              },
      );
    },
  );

  Future<void> _confirm(BuildContext context, PlanPreviewModel model) async {
    final proposal = widget.planning?.preview(widget.proposalId);
    final application = widget.application;
    if (proposal == null || application == null) return;

    final result = await application.apply(proposal);
    if (!context.mounted) return;

    final message = switch (result.status) {
      ApplyPlanStatus.applied => '计划已更新',
      ApplyPlanStatus.staleProposal => '输入已变化，计划已过期，请重新生成',
      ApplyPlanStatus.invalidProposal => '计划未通过校验，未应用',
    };
    showPlannerMessage(context, message: message);
    if (result.status == ApplyPlanStatus.applied) {
      context.go('/calendar');
    }
  }
}

Future<void> _undoTimetableImport(
  BuildContext context,
  TimetableImportService importer,
  String batchId,
) async {
  try {
    final preview = await importer.inspectRollback(batchId);
    if (!context.mounted) return;
    var force = const <String>{};
    if (preview.protectedEventIds.isNotEmpty) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('有课程在导入后被修改过'),
          content: Text(
            '共 ${preview.protectedEventIds.length} 组课程有手动修改或新增例外。'
            '继续撤销会一并删除这些修改。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('仍然撤销'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      force = preview.protectedEventIds;
    }
    final result = await importer.rollback(batchId, forceEventIds: force);
    if (!context.mounted) return;
    showPlannerMessage(
      context,
      message: '已撤销本次导入，删除 ${result.deletedEventCount} 组课程',
    );
  } on Object {
    if (!context.mounted) return;
    showPlannerMessage(context, message: '撤销失败：课程可能在确认期间再次发生变化');
  }
}

PreviewChangeKind _kindOf(PlanChange change) => switch (change.type) {
  PlanChangeType.added => PreviewChangeKind.added,
  PlanChangeType.moved => PreviewChangeKind.moved,
  PlanChangeType.split => PreviewChangeKind.split,
  // `removed` 在 M4 的五类体系里由「未安排」承担（见 `PreviewChangeKind` 的注释：
  // 没排进去不等于被移除，任务还在）。
  PlanChangeType.removed => PreviewChangeKind.unplanned,
};

/// 材质模式的中文短名（M8：设置首页每个入口要展示当前值）。
///
/// **为什么在路由器里而不是在枚举上**：`PlannerMaterialMode` 是领域层的枚举，
/// 而"在设置首页那一行里怎么称呼它"是**这一处的文案**，不是这个概念的固有属性
/// （外观页自己有更长的说法）。把它挂在枚举上会让领域层承担界面文案。
String _materialLabel(PlannerMaterialMode mode) => switch (mode) {
  PlannerMaterialMode.off => '无玻璃',
  PlannerMaterialMode.restrained => '克制',
  PlannerMaterialMode.aggressive => '激进',
  PlannerMaterialMode.liquid => '极致液态玻璃',
};

/// 一个计划块的**本地时间人话写法**；块为空时返回 `null`。
///
/// M4：新增没有原时间、未安排没有目标时间，因此这个函数必须能表达"这一侧没有"。
String? _timeLabelOf(
  TimeZoneDatabase zones,
  String timeZoneId,
  PlannedBlock? block,
) {
  if (block == null) return null;
  final start = zones.toLocal(block.startUtc, timeZoneId);
  final end = zones.toLocal(block.endUtc, timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}:${two(start.minute)}–'
      '${two(end.hour)}:${two(end.minute)}';
}

String _titleOf(TimeZoneDatabase zones, String timeZoneId, PlanChange change) {
  final block = change.after ?? change.before;
  if (block == null) return change.blockId;
  final start = zones.toLocal(block.startUtc, timeZoneId);
  final end = zones.toLocal(block.endUtc, timeZoneId);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${block.taskId}  ${two(start.month)}-${two(start.day)} '
      '${two(start.hour)}:${two(start.minute)}–${two(end.hour)}:${two(end.minute)}';
}
