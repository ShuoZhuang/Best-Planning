// Task 7（计划 §2.6）：**日历刷新使用显式失效信号**。
//
// 这个文件钉住三件事，缺一件上面的机制就会退化成"看起来接好了"：
//
// 1. **总线本身**：revision 从 1 起单调递增、broadcast、无监听者时 `notify` 不抛、
//    `dispose()` 幂等、dispose 之后 `notify` 安全忽略；
// 2. **生产装配**：`main.dart` 的六个写入点全部接到**同一条** app-scoped 总线上，
//    且两条时序规则（先记重排原因／先同步提醒，再发信号；前者失败也发）；
// 3. **每个写入点**：成功一次发一个信号，失败／stale／取消发零次；
//    经 `CalendarService` 的课程写入**不得**产生两次刷新。
//
// 用真实 drift 内存库的只有课程那三条：只有真的写入，"零信号"与"只发一次"才有意义。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/calendar_service.dart';
import 'package:personal_planner/application/course_management_service.dart';
import 'package:personal_planner/application/input_snapshot_builder.dart';
import 'package:personal_planner/application/plan_application_service.dart';
import 'package:personal_planner/application/plan_undo_service.dart';
import 'package:personal_planner/application/planning_service.dart';
import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/application/schedule_color_service.dart';
import 'package:personal_planner/application/schedule_view_invalidation.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart'
    hide CalendarEvent, RecurrenceRule;
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_course_series_repository.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/planning_rules.dart';
import 'package:personal_planner/domain/models/preferences.dart';
import 'package:personal_planner/domain/models/schedule_colors.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/plan_repository.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/domain/services/default_settings.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

void main() {
  group('失效总线（§2.6）', () {
    test('revision 从 1 开始单调递增', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final seen = <int>[];
      final subscription = bus.revisions.listen(seen.add);

      // 从 1 开始：`0` 因此永远不出现在流上，订阅者不必把它当成"尚未加载"。
      bus.notify(ScheduleViewChangeKind.colors);
      bus.notify(ScheduleViewChangeKind.planningRules);
      bus.notify(ScheduleViewChangeKind.calendar);
      await pumpEventQueue();
      expect(seen, [1, 2, 3], reason: '第一次 notify 得到 1，随后逐个递增');
      await subscription.cancel();
    });

    test('无监听者时 notify 不抛错，也不补发历史修订号', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);

      // **启动阶段"补齐默认领域"之类的写入发生在任何页面订阅之前**：broadcast 控制器
      // 把它们直接丢掉，既不抛错、也不在之后补发——补发会让新订阅者立刻白刷一次。
      bus.notify(ScheduleViewChangeKind.workspace);
      bus.notify(ScheduleViewChangeKind.calendar);
      await pumpEventQueue();

      final seen = <int>[];
      final subscription = bus.revisions.listen(seen.add);
      bus.notify(ScheduleViewChangeKind.plan);
      await pumpEventQueue();
      expect(seen, [3], reason: '订阅只收到订阅之后的那一份修订号');
      await subscription.cancel();
    });

    test('broadcast：多个订阅者各自收到同一串修订号', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final first = <int>[];
      final second = <int>[];
      final a = bus.revisions.listen(first.add);
      final b = bus.revisions.listen(second.add);
      addTearDown(a.cancel);
      addTearDown(b.cancel);

      bus.notify(ScheduleViewChangeKind.calendar);
      bus.notify(ScheduleViewChangeKind.plan);
      await pumpEventQueue();

      // 单订阅控制器会在第二个页面订阅时直接抛 "Stream has already been listened to"。
      expect(first, [1, 2]);
      expect(second, [1, 2]);
    });

    test('dispose 幂等，且之后的 notify 被安全忽略', () async {
      final bus = ScheduleViewInvalidationBus();
      final seen = <int>[];
      final subscription = bus.revisions.listen(seen.add);
      bus.notify(ScheduleViewChangeKind.calendar);
      await pumpEventQueue();
      expect(seen, [1]);

      await bus.dispose();
      await bus.dispose();
      await bus.dispose();

      // **不得抛异常，也不得产生未捕获异常**：关闭窗口时那几条在途写入仍可能回来，
      // 而 controller 已经关闭——直接 `add` 会抛 `StateError`，成为一条无人处理的错误。
      // 本用例在 flutter_test 里运行，因此任何未捕获的异步异常都会让测试失败。
      bus.notify(ScheduleViewChangeKind.calendar);
      bus.notify(ScheduleViewChangeKind.plan);
      await pumpEventQueue();
      expect(seen, [1], reason: 'dispose 之后不再产生修订号');
      await subscription.cancel();
    });
  });

  group('生产装配（main.dart，§2.6 的装配规则）', () {
    test('六个写入点全部有接线，而且都发在同一条总线上', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);

      // 全部非空：`main.dart` 用的是**同一组**回调，因此这里判空就是判生产装配。
      expect(wiring.calendar, isNotNull);
      expect(wiring.colors, isNotNull);
      expect(wiring.workspace, isNotNull);
      expect(wiring.planningRules, isNotNull);
      expect(
        wiring.calendarAfter((change) {}),
        isNotNull,
        reason: 'CalendarService 的成功写入（固定日程／保护时间／课程改写）',
      );
      expect(
        wiring.planAfter(() async {}),
        isNotNull,
        reason: 'PlanApplicationService 与 PlanUndoService 的成功写入',
      );

      final seen = <int>[];
      final subscription = bus.revisions.listen(seen.add);
      wiring.calendarAfter((change) {})(
        const ScheduleInputChange(
          label: '固定日程创建',
          kind: DomainChangeKind.fixedEventCreated,
        ),
      );
      wiring.calendar();
      wiring.colors();
      wiring.workspace();
      wiring.planningRules();
      await wiring.planAfter(() async {})();
      await pumpEventQueue();
      await subscription.cancel();

      expect(seen, [1, 2, 3, 4, 5, 6], reason: '六个写入点各自只发一份修订号，而且全部发在这一条总线上');
    });

    test('重排记录抛错时仍必须发出 calendar 信号（数据已经落库）', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);

      final seen = <int>[];
      final subscription = bus.revisions.listen(seen.add);
      expect(
        () => wiring.calendarAfter((change) => throw StateError('统计模块炸了'))(
          const ScheduleInputChange(
            label: '固定日程创建',
            kind: DomainChangeKind.fixedEventCreated,
          ),
        ),
        throwsStateError,
      );
      await pumpEventQueue();
      await subscription.cancel();
      expect(seen, [1], reason: '统计记录失败不影响"数据已经写进去了"这个事实；不发信号会让日历停在旧内容上');
    });

    test('提醒同步失败时仍必须发出 plan 信号（计划已经提交）', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);

      final seen = <int>[];
      final subscription = bus.revisions.listen(seen.add);
      await expectLater(
        wiring.planAfter(() async => throw StateError('提醒同步失败（夹具）'))(),
        throwsStateError,
      );
      await pumpEventQueue();
      await subscription.cancel();
      expect(seen, [1], reason: '**不能把已经落库的计划假装成没写入**（§2.6）：同步失败也必须让页面读回真实结果');
    });

    test('main.dart 只创建一个 app-scoped 总线，并把它交给每个写入点与数据源', () {
      // 组合根不可能在单元测试里真的跑起来（它打开真实数据库并 `runApp`），
      // 因此这里对着源码钉住"接线是否都在"。判据与格式无关：只看标识符出现的方式。
      final source = File('lib/main.dart').readAsStringSync();

      expect(
        'ScheduleViewInvalidationBus('.allMatches(source).length,
        1,
        reason:
            '**整个应用只能有一个**失效总线实例（§2.6）。每个页面各建一套会让'
            '"某条写入路径忘了通知"表现为"只有一个页面没刷新"，正好把这个缺陷藏起来',
      );
      for (final wiring in const [
        'onScheduleInputChanged: invalidation.calendarAfter',
        'onPlanChanged: invalidation.planAfter',
        'onCalendarChanged: invalidation.calendar',
        'onPlanningRulesChanged: invalidation.planningRules',
        'onColorsChanged: invalidation.colors',
        'onWorkspaceChanged: invalidation.workspace',
        'invalidation: scheduleInvalidation',
        'scheduleInvalidation: scheduleInvalidation',
      ]) {
        expect(source, contains(wiring), reason: '组合根必须装配 `$wiring`');
      }
      expect(
        source,
        isNot(contains('ScheduleViewChangeKind.task')),
        reason: '任务展示刷新由 `tasks.watchAllTasks()` 驱动，**不重复**发 bus 信号（§2.6）',
      );
    });
  });

  group('CalendarService：成功发一次、失败与 stale 发零次', () {
    test('改写整个系列成功 ⇒ 恰好一次信号，且既有重排记录仍在', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);
      final reasons = <String>[];
      final deletion = _Deletion();
      final service = _calendarService(
        deletion: deletion,
        onScheduleInputChanged: wiring.calendarAfter(
          (change) => reasons.add(change.label),
        ),
      );

      final signals = await _signalsOf(
        bus,
        () async => service.updateEvent(
          target: const CalendarEditTarget(
            anchorId: 'a1',
            scope: EventEditScope.entireSeries,
          ),
          patch: _calendarDraft(),
        ),
      );

      expect(deletion.writes, 1);
      expect(signals, 1, reason: '成功写入恰好发一次：多发就是同一次改动刷新两次');
      expect(reasons, ['固定日程系列改写'], reason: '既有的"重排原因"记录必须原样保留（不能为了新信号把它挤掉）');
    });

    test('端口抛错 ⇒ 零信号（数据没变就没有要刷新的东西）', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);
      final deletion = _Deletion()..throwOnReplace = true;
      final service = _calendarService(
        deletion: deletion,
        onScheduleInputChanged: wiring.calendarAfter((change) {}),
      );

      late CalendarMutationResult result;
      final signals = await _signalsOf(bus, () async {
        result = await service.updateEvent(
          target: const CalendarEditTarget(
            anchorId: 'a1',
            scope: EventEditScope.entireSeries,
          ),
          patch: _calendarDraft(),
        );
      });

      expect(result.status, CalendarMutationStatus.failed);
      expect(signals, 0);
    });

    test('乐观并发判为 stale ⇒ 零信号', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);
      final deletion = _Deletion();
      final service = _calendarService(
        deletion: deletion,
        onScheduleInputChanged: wiring.calendarAfter((change) {}),
        // 页面上读到的是**上一版**：服务层必须拒绝，且什么都没写。
        currentUpdatedAt: DateTime.utc(2026, 10, 12, 9),
      );

      late CalendarMutationResult result;
      final signals = await _signalsOf(bus, () async {
        result = await service.updateEvent(
          target: CalendarEditTarget(
            anchorId: 'a1',
            scope: EventEditScope.entireSeries,
            expectedUpdatedAtUtc: DateTime.utc(2026, 10, 12, 8),
          ),
          patch: _calendarDraft(),
        );
      });

      expect(result.status, CalendarMutationStatus.stale);
      expect(deletion.writes, 0);
      expect(signals, 0);
    });

    test('新建固定日程成功 ⇒ 一次信号；草稿非法 ⇒ 零信号', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);
      final service = _calendarService(
        deletion: _Deletion(),
        onScheduleInputChanged: wiring.calendarAfter((change) {}),
      );

      final saved = await _signalsOf(
        bus,
        () async => service.save(
          EventDraft(
            title: '数据结构课',
            startAtUtc: DateTime.utc(2026, 10, 13, 1),
            endAtUtc: DateTime.utc(2026, 10, 13, 2),
            timeZoneId: 'Asia/Shanghai',
          ),
        ),
      );
      expect(saved, 1);

      final invalid = await _signalsOf(
        bus,
        () async => service.save(
          EventDraft(
            title: '   ',
            startAtUtc: DateTime.utc(2026, 10, 13, 1),
            endAtUtc: DateTime.utc(2026, 10, 13, 2),
            timeZoneId: 'Asia/Shanghai',
          ),
        ),
      );
      expect(invalid, 0, reason: '草稿非法 ⇒ 零写入，也就零信号');
    });

    test('删除固定日程成功 ⇒ 一次信号', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);
      final service = _calendarService(
        deletion: _Deletion(),
        onScheduleInputChanged: wiring.calendarAfter((change) {}),
      );

      expect(await _signalsOf(bus, () => service.deleteEvent('e1')), 1);
    });
  });

  group('计划写入（应用与撤销）', () {
    test('应用成功 ⇒ 一次 plan 信号；stale ⇒ 零信号', () async {
      final plans = _Plans();
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final wiring = ScheduleViewInvalidationWiring(bus);
      final taps = <int>[];
      final service = PlanApplicationService(
        source: _ProblemSource(_problem()),
        repository: plans,
        zones: TimeZoneDatabase(),
        onPlanChanged: wiring.planAfter(() async => taps.add(1)),
      );

      const snapshots = InputSnapshotBuilder();
      final applied = await _signalsOf(
        bus,
        () async => service.apply(
          _proposal(
            inputHash: snapshots.hash(InputSnapshot(problem: _problem())),
          ),
        ),
      );
      expect(plans.applyCalls, 1);
      expect(taps, hasLength(1), reason: '既有的提醒同步必须先跑完');
      expect(applied, 1);

      final stale = await _signalsOf(
        bus,
        () async => service.apply(_proposal(inputHash: 'no-such-hash')),
      );
      expect(stale, 0, reason: '过期提案没有改变当前计划');
    });

    test('引擎已报阻断冲突 ⇒ 零信号（连仓储都没写）', () async {
      final plans = _Plans();
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = PlanApplicationService(
        source: _ProblemSource(_problem()),
        repository: plans,
        zones: TimeZoneDatabase(),
        onPlanChanged: ScheduleViewInvalidationWiring(bus)
            .planAfter(() async {}),
      );
      const snapshots = InputSnapshotBuilder();

      final signals = await _signalsOf(
        bus,
        () async => service.apply(
          _proposal(
            inputHash: snapshots.hash(InputSnapshot(problem: _problem())),
            conflicts: [
              PlanningConflict(code: ConflictCode.schedulingInvariantViolation),
            ],
          ),
        ),
      );

      expect(plans.applyCalls, 0);
      expect(signals, 0);
    });

    test('撤销成功 ⇒ 一次 plan 信号；无可撤销 ⇒ 零信号', () async {
      final plans = _Plans()
        ..currentPlan = _confirmedPlan()
        ..previousPlan = _confirmedPlan();
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = PlanUndoService(
        repository: plans,
        onPlanChanged: ScheduleViewInvalidationWiring(bus)
            .planAfter(() async {}),
      );

      expect(await _signalsOf(bus, () => service.undoLastAppliedPlan()), 1);

      final empty = _Plans()
        ..currentPlan = _confirmedPlan()
        ..previousPlan = null;
      final nothingToUndo = PlanUndoService(
        repository: empty,
        onPlanChanged: ScheduleViewInvalidationWiring(bus)
            .planAfter(() async {}),
      );
      expect(
        await _signalsOf(bus, () => nothingToUndo.undoLastAppliedPlan()),
        0,
        reason: '"无可撤销"抛 StateError：当前计划没变，因此零信号',
      );
    });
  });

  group('SettingsService：只有规划规则成功保存才发', () {
    test('saveUserRules / saveDateOverride 成功各发一次', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = SettingsService(
        repository: MemorySettingsRepository(),
        onPlanningRulesChanged: ScheduleViewInvalidationWiring(bus)
            .planningRules,
      );

      expect(
        await _signalsOf(
          bus,
          () => service.saveUserRules(
            const UserPlanningRules(
              common: PlanningRulesPatch(minChunkMinutes: 25),
            ),
          ),
        ),
        1,
      );
      expect(
        await _signalsOf(
          bus,
          () => service.saveDateOverride(
            DateTime(2026, 10, 13),
            const PlanningRulesPatch(dailyMovableTaskLimitMinutes: 120),
          ),
        ),
        1,
      );
    });

    test('校验失败 ⇒ 零信号；无关设置一律不发', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = SettingsService(
        repository: MemorySettingsRepository(),
        onPlanningRulesChanged: ScheduleViewInvalidationWiring(bus)
            .planningRules,
      );

      // minChunkMinutes 必须 > 0：非法规则抛 SettingsValidationException 且零写入。
      expect(
        await _signalsOf(
          bus,
          () => service.saveUserRules(
            const UserPlanningRules(
              common: PlanningRulesPatch(minChunkMinutes: 0),
            ),
          ),
        ),
        0,
      );
      expect(
        await _signalsOf(
          bus,
          () => service.saveDateOverride(
            DateTime(2026, 10, 13),
            const PlanningRulesPatch(defaultFocusMinutes: 0),
          ),
        ),
        0,
      );

      // **通知设置、关闭行为与信任自动调整都不是规划规则**：它们不改变任何一条日历条目，
      // 发信号只会让三个页面白读一次库。
      expect(
        await _signalsOf(
          bus,
          () => service.saveNotificationPreferences(NotificationPreferences()),
        ),
        0,
      );
      expect(
        await _signalsOf(
          bus,
          () => service.saveCloseBehavior(WindowCloseBehavior.minimizeToTray),
        ),
        0,
      );
      expect(await _signalsOf(bus, () => service.setTrustAutoAdjust(true)), 0);
    });
  });

  group('ScheduleColorService：只有颜色写入成功才发', () {
    test('setSpecialColor 成功 ⇒ 一次；越界颜色 ⇒ 零次', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = ScheduleColorService(
        settings: MemorySettingsRepository(),
        workspace: _WorkspaceRepo(),
        onColorsChanged: ScheduleViewInvalidationWiring(bus).colors,
      );

      expect(
        await _signalsOf(
          bus,
          () => service.setSpecialColor(
            ScheduleSpecialCategory.protectedTime,
            0xff5ec8e5,
          ),
        ),
        1,
      );
      expect(
        await _signalsOf(
          bus,
          () => service.setSpecialColor(
            ScheduleSpecialCategory.unassignedTask,
            0x005ec8e5,
          ),
        ),
        0,
        reason: '不透明色校验失败的路径什么都没改：零写入、零信号',
      );
    });
  });

  group('WorkspaceService：只有改变日历分类名称／颜色的写入才发', () {
    test('新建、改名与改色各发一次；越界颜色不发', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = WorkspaceService(
        repository: _WorkspaceRepo(),
        clock: _Clock(DateTime.utc(2026, 10, 12, 9)),
        idGenerator: _Ids(),
        onWorkspaceChanged: ScheduleViewInvalidationWiring(bus).workspace,
      );

      late PlannerArea area;
      expect(
        await _signalsOf(bus, () async {
          area = await service.createArea('学业');
        }),
        1,
        reason: '新领域就是一个新的日历分类',
      );
      expect(await _signalsOf(bus, () => service.renameArea(area, '学业（新）')), 1);
      expect(
        await _signalsOf(bus, () => service.setAreaColor(area.id, 0xff2f86ff)),
        1,
      );
      expect(
        await _signalsOf(bus, () => service.setAreaColor(area.id, 0x002f86ff)),
        0,
        reason: '越界颜色 ⇒ 零写入',
      );
    });

    test('生活标记与项目操作不发信号', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = WorkspaceService(
        repository: _WorkspaceRepo(),
        clock: _Clock(DateTime.utc(2026, 10, 12, 9)),
        idGenerator: _Ids(),
        onWorkspaceChanged: ScheduleViewInvalidationWiring(bus).workspace,
      );
      final area = await service.createArea('学业');

      // **它们不影响日历卡片上的名称或颜色**：`isLife` 只进统计口径，
      // 项目也不画在日历卡片上。发信号只会让三个页面白读一次库。
      expect(await _signalsOf(bus, () => service.setAreaLife(area, true)), 0);
      expect(
        await _signalsOf(bus, () async {
          final created = await service.createProject(
            name: '课程设计',
            areaId: area.id,
          );
          await service.renameProject(created, '课程设计（新）');
          await service.archiveProject(created, archived: true);
        }),
        0,
        reason: '项目的增改归档都不改变日历分类的名称或颜色',
      );
    });

    test('补齐默认领域：真的新建了才发一次，重复调用不发', () async {
      final bus = ScheduleViewInvalidationBus();
      addTearDown(bus.dispose);
      final service = WorkspaceService(
        repository: _WorkspaceRepo(),
        clock: _Clock(DateTime.utc(2026, 10, 12, 9)),
        idGenerator: _Ids(),
        onWorkspaceChanged: ScheduleViewInvalidationWiring(bus).workspace,
      );

      expect(await _signalsOf(bus, () => service.ensureDefaultAreas()), 1);
      expect(
        await _signalsOf(bus, () => service.ensureDefaultAreas()),
        0,
        reason: '一个都没建 ⇒ 这次调用没有改变任何分类',
      );
    });
  });

  group('CourseManagementService：只有绕过 CalendarService 的事务才发', () {
    late AppDatabase database;
    late DriftCalendarRepository repository;
    late DriftCourseSeriesRepository courses;
    late ScheduleViewInvalidationBus bus;

    final nowUtc = DateTime.utc(2026, 10, 12, 1, 30);

    setUp(() async {
      database = AppDatabase.forTesting(NativeDatabase.memory());
      repository = DriftCalendarRepository(database, zones: TimeZoneDatabase());
      courses = DriftCourseSeriesRepository(
        database,
        clock: _Clock(nowUtc),
        zones: TimeZoneDatabase(),
        timeZoneId: 'Asia/Shanghai',
      );
      bus = ScheduleViewInvalidationBus();
      await database.customInsert('''
        INSERT INTO academic_terms
          (id, name, first_week_monday_local_date, total_weeks, time_zone_id,
           created_at_utc, updated_at_utc)
        VALUES ('term-autumn', '2026 秋季学期', '2026-09-07', 16,
                'Asia/Shanghai', 1, 1)
      ''');
      await database.customInsert('''
        INSERT INTO timetable_import_batches
          (id, term_id, source_image_hash, source_file_name, status,
           created_event_count, created_at_utc, updated_at_utc)
        VALUES ('batch-autumn', 'term-autumn', 'sha256:x', 'schedule.png',
                'committed', 1, 1, 1)
      ''');
    });

    tearDown(() async {
      await bus.dispose();
      await database.close();
    });

    Future<void> seedSegment() => repository.saveRecurring(
      CalendarEvent(
        id: 'evt-a',
        title: '高等数学(上)',
        startAtUtc: DateTime.utc(2026, 9, 7, 0),
        endAtUtc: DateTime.utc(2026, 9, 7, 0, 45),
        timeZoneId: 'Asia/Shanghai',
        recurrenceRuleId: 'rule-a',
        sourceKind: CalendarEventSourceKind.timetableImport,
        importBatchId: 'batch-autumn',
        logicalCourseId: 'course-calc',
        updatedAtUtc: DateTime.utc(2026, 10, 1),
      ),
      RecurrenceRule(
        id: 'rule-a',
        weekdays: const {DateTime.monday},
        localStartMinute: 8 * 60,
        durationMinutes: 45,
        validFromLocalDate: DateTime(2026, 9, 7),
        validUntilLocalDate: DateTime(2026, 12, 20),
        timeZoneId: 'Asia/Shanghai',
      ),
    );

    /// 生产形状的课程服务：日历侧与课程侧**共用同一条总线**。
    CourseManagementService serviceWith({List<String>? calendarReasons}) =>
        CourseManagementService(
          courses: courses,
          calendar: CalendarService(
            repository: repository,
            deletion: repository,
            recurringRepository: repository,
            clock: _Clock(nowUtc),
            idGenerator: _Ids(),
            zones: TimeZoneDatabase(),
            onScheduleInputChanged: ScheduleViewInvalidationWiring(bus)
                .calendarAfter((change) => calendarReasons?.add(change.label)),
          ),
          deletion: repository,
          gateway: repository,
          zones: TimeZoneDatabase(),
          timeZoneId: 'Asia/Shanghai',
          clock: _Clock(nowUtc),
          onCalendarChanged: ScheduleViewInvalidationWiring(bus).calendar,
        );

    Future<CourseSaveRequest> requestFor({
      String? fingerprint,
      Map<String, DateTime>? revisions,
    }) async {
      final detail = await courses.findCourse('course-calc');
      return CourseSaveRequest(
        logicalCourseId: 'course-calc',
        expectedRevisions: revisions ?? detail!.sourceRevisions,
        expectedFingerprint: fingerprint ?? detail!.revisionFingerprint,
        profile: CourseProfileDraft(
          logicalCourseId: 'course-calc',
          title: '高等数学(下)',
          schedule: [_courseDraft()],
        ),
      );
    }

    test('saveCourse 成功 ⇒ 恰好一次信号', () async {
      await seedSegment();
      final service = serviceWith();

      final signals = await _signalsOf(
        bus,
        () async => service.saveCourse(await requestFor()),
      );

      expect(signals, 1, reason: '这条路径绕过 CalendarService，只能由课程服务自己发');
    });

    test('saveCourse 判为 stale ⇒ 零信号', () async {
      await seedSegment();
      final service = serviceWith();

      final signals = await _signalsOf(
        bus,
        () async => service.saveCourse(
          await requestFor(fingerprint: 'stale-fingerprint'),
        ),
      );

      expect(signals, 0);
    });

    test('时区未装配 ⇒ unsupported（零写入、零信号）', () async {
      await seedSegment();
      final service = CourseManagementService(
        courses: courses,
        calendar: CalendarService(
          repository: repository,
          deletion: repository,
          recurringRepository: repository,
          clock: _Clock(nowUtc),
          idGenerator: _Ids(),
          zones: TimeZoneDatabase(),
          onScheduleInputChanged: ScheduleViewInvalidationWiring(bus)
              .calendarAfter((change) {}),
        ),
        deletion: repository,
        gateway: repository,
        // 刻意不传 timeZoneId / clock：`saveCourse` 会拒绝写入。
        onCalendarChanged: ScheduleViewInvalidationWiring(bus).calendar,
      );

      final signals = await _signalsOf(
        bus,
        () async => service.saveCourse(await requestFor()),
      );

      expect(signals, 0);
    });

    test('deleteCourse 成功 ⇒ 一次；课程不存在 ⇒ 零次', () async {
      await seedSegment();
      final service = serviceWith();

      expect(
        await _signalsOf(bus, () => service.deleteCourse('course-calc')),
        1,
      );
      expect(
        await _signalsOf(bus, () => service.deleteCourse('course-calc')),
        0,
        reason: '课程已经不在了：什么都没删，因此零信号',
      );
    });

    test('**经过 CalendarService 的课程改写只产生一次刷新**', () async {
      await seedSegment();
      final reasons = <String>[];
      final service = serviceWith(calendarReasons: reasons);

      // 单次／"此次及以后"／整条系列三种范围改写**统一走 `updateEvent` ＋ patch**
      // （计划 §2.0.1）：`CourseManagementService.editOccurrence` 那三个只收时间的
      // 包装器已随 Task 3 删除，因此这里直接驱动日历服务——那正是日视图的真实路径。
      final signals = await _signalsOf(
        bus,
        () async => service.calendar.updateEvent(
          target: const CalendarEditTarget(
            anchorId: 'evt-a',
            scope: EventEditScope.entireSeries,
          ),
          patch: CalendarEventPatch(
            title: '高等数学(上)',
            startAtUtc: DateTime.utc(2026, 10, 12, 4),
            endAtUtc: DateTime.utc(2026, 10, 12, 4, 45),
          ),
        ),
      );

      expect(reasons, isNotEmpty, reason: '这条路径的重排原因由 CalendarService 记');
      expect(
        signals,
        1,
        reason:
            '课程服务**不得**为经过 CalendarService 的写入再发一次：'
            '那会让同一次改动触发两次完整刷新',
      );
    });
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 夹具
// ─────────────────────────────────────────────────────────────────────────────

/// 执行一次写入，返回**总线收到的修订号个数**。
///
/// 写入抛出的异常在这里被吞掉：本文件要判的正是"失败必须发零次"，
/// 而"确实抛了"由各自的用例单独覆盖（如 `expect(() => ..., throwsStateError)`）。
Future<int> _signalsOf(
  ScheduleViewInvalidation bus,
  Future<void> Function() action,
) async {
  final seen = <int>[];
  final subscription = bus.revisions.listen(seen.add);
  try {
    await action();
  } on Object {
    // 见上。
  }
  await pumpEventQueue();
  await subscription.cancel();
  return seen.length;
}

final class _Clock implements Clock {
  const _Clock(this.value);

  final DateTime value;

  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'generated-${++_count}';
}

final class _WorkspaceRepo implements WorkspaceRepository {
  final List<PlannerArea> areas = [];
  final List<PlannerProject> projects = [];

  @override
  Future<List<PlannerArea>> listAreas() async => List.of(areas);

  @override
  Future<List<PlannerProject>> listProjects() async => List.of(projects);

  @override
  Future<void> saveArea(PlannerArea area) async {
    final index = areas.indexWhere((item) => item.id == area.id);
    if (index < 0) {
      areas.add(area);
    } else {
      areas[index] = area;
    }
  }

  @override
  Future<void> saveProject(PlannerProject project) async {
    final index = projects.indexWhere((item) => item.id == project.id);
    if (index < 0) {
      projects.add(project);
    } else {
      projects[index] = project;
    }
  }
}

final class _CalendarRepo implements CalendarRepository {
  _CalendarRepo(this.occurrences);

  /// `_currentUpdatedAtOf` 与 `_isProtectedEvent` 都读它。
  final List<CalendarOccurrence> occurrences;

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => List.of(occurrences);

  @override
  Future<void> save(CalendarEvent event) async {}
}

final class _Deletion implements CalendarEventDeletion {
  int writes = 0;
  bool throwOnReplace = false;

  /// 库里的"当前修订号"。**乐观并发判定现在发生在写端口的事务里**
  /// （计划 Task 2 Step 3），因此这个值必须由替身持有——服务层不再自己读一遍。
  DateTime? currentUpdatedAt;

  void _count() => writes++;

  /// 替身版的"事务内核对修订号"：不一致时抛 [CalendarEditStaleException]，
  /// 锚点不在且调用方给过期望值时抛 [CalendarEditMissingException]，**两者都零写入**。
  void _assertRevision(DateTime? expectedUpdatedAtUtc) {
    if (expectedUpdatedAtUtc == null) return;
    final current = currentUpdatedAt;
    if (current == null) throw const CalendarEditMissingException();
    if (current.microsecondsSinceEpoch !=
        expectedUpdatedAtUtc.microsecondsSinceEpoch) {
      throw const CalendarEditStaleException();
    }
  }

  @override
  Future<void> deleteEvent(String eventId) async => _count();

  @override
  Future<void> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async => _count();

  @override
  Future<void> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime updatedAtUtc,
  }) async => _count();

  @override
  Future<void> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    required String exceptionId,
    required DateTime updatedAtUtc,
  }) async {
    _assertRevision(expectedUpdatedAtUtc);
    if (throwOnReplace) throw StateError('数据库炸了');
    _count();
  }

  @override
  Future<void> replaceSeries({
    required String anchorId,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    required DateTime updatedAtUtc,
    DateTime? updateExceptionsFromUtc,
  }) async {
    _assertRevision(expectedUpdatedAtUtc);
    if (throwOnReplace) throw StateError('写入失败（夹具）');
    _count();
  }

  @override
  Future<void> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required CalendarEventPatch patch,
    DateTime? expectedUpdatedAtUtc,
    RecurrenceEditDraft? recurrence,
    required String newRuleId,
    required String newEventId,
    required DateTime updatedAtUtc,
  }) async {
    _assertRevision(expectedUpdatedAtUtc);
    if (throwOnReplace) throw StateError('写入失败（夹具）');
    _count();
  }

  @override
  Future<void> setEventArea({
    required String eventId,
    required String? areaId,
    required DateTime updatedAtUtc,
  }) async => _count();
}

CalendarService _calendarService({
  required CalendarEventDeletion deletion,
  required void Function(ScheduleInputChange change) onScheduleInputChanged,
  DateTime? currentUpdatedAt,
}) {
  // **乐观并发判定搬进了写端口**（计划 Task 2 Step 3）：因此这里把"库里的当前修订号"
  // 交给替身，而不是塞进读仓储——服务层已经不再读那一次了。
  if (deletion is _Deletion) deletion.currentUpdatedAt = currentUpdatedAt;
  return CalendarService(
    repository: _CalendarRepo([
      if (currentUpdatedAt != null)
        CalendarOccurrence(
          eventId: 'a1',
          title: '固定日程',
          range: TimeRange(
            startUtc: DateTime.utc(2026, 10, 12, 1),
            endUtc: DateTime.utc(2026, 10, 12, 2),
          ),
          locked: true,
          updatedAtUtc: currentUpdatedAt,
        ),
    ]),
    deletion: deletion,
    clock: _Clock(DateTime.utc(2026, 10, 12, 9)),
    idGenerator: _Ids(),
    zones: TimeZoneDatabase(),
    onScheduleInputChanged: onScheduleInputChanged,
  );
}

CalendarEventPatch _calendarDraft() => CalendarEventPatch(
  title: '看医生',
  startAtUtc: DateTime.utc(2026, 10, 12, 1),
  endAtUtc: DateTime.utc(2026, 10, 12, 2),
);

/// 计划仓储替身：应用与撤销都要能观察"到底有没有写"。
final class _Plans implements PlanRepository, PlanHistoryRepository {
  ConfirmedPlan? currentPlan;
  ConfirmedPlan? previousPlan;
  int applyCalls = 0;

  @override
  Future<ConfirmedPlan?> current() async => currentPlan;

  @override
  Future<ConfirmedPlan?> previous() async => previousPlan;

  @override
  Future<ConfirmedPlan> restoreAsNewVersion({
    required ConfirmedPlan source,
    required ConfirmedPlan replaced,
  }) async {
    currentPlan = source;
    return source;
  }

  @override
  Future<ApplyPlanResult> applyProposal(
    ScheduleProposal proposal,
    String expectedInputHash,
  ) async {
    applyCalls++;
    final plan = ConfirmedPlan(
      id: 'applied',
      inputHash: expectedInputHash,
      algorithmVersion: '16',
      blocks: proposal.blocks,
    );
    currentPlan = plan;
    previousPlan = plan;
    return ApplyPlanResult.applied(plan);
  }
}

ConfirmedPlan _confirmedPlan() => ConfirmedPlan(
  id: 'plan-1',
  inputHash: 'hash',
  algorithmVersion: '16',
  blocks: const [],
);

/// 一份**没有任务也没有块**的排程输入：判"发了几次信号"不需要真排程，
/// 但校验器、哈希与窗口必须是真实的（否则测的是替身的行为）。
ScheduleProblem _problem() => ScheduleProblem(
  planningWindow: TimeRange(
    startUtc: DateTime.utc(2026, 10, 12),
    endUtc: DateTime.utc(2026, 10, 13),
  ),
  timeZoneId: 'UTC',
  tasks: const [],
  fixedIntervals: const [],
  protectedIntervals: const [],
  lockedBlocks: const [],
  rules: DefaultSettings.v1(),
  preferences: const PreferenceProfile(),
  inputHash: 'ignored',
);

ScheduleProposal _proposal({
  required String inputHash,
  List<PlanningConflict> conflicts = const [],
}) => ScheduleProposal(
  proposalId: 'proposal-1',
  inputHash: inputHash,
  algorithmVersion: '16',
  planningWindow: TimeRange(
    startUtc: DateTime.utc(2026, 10, 12),
    endUtc: DateTime.utc(2026, 10, 13),
  ),
  blocks: const [],
  unscheduled: const [],
  conflicts: conflicts,
  explanations: const [],
  metrics: const ProposalMetrics(
    isFullyFeasible: true,
    scheduledMinutes: 0,
    unscheduledMinutes: 0,
  ),
);

final class _ProblemSource implements ScheduleProblemSource {
  const _ProblemSource(this.problem);
  final ScheduleProblem problem;

  @override
  Future<ScheduleProblem> load({ScheduleRuleOverride? override}) async =>
      problem;
}

/// 与 `course_edit_save_test.dart` 同形的一条课程安排草稿。
CourseScheduleDraft _courseDraft() => CourseScheduleDraft(
  startMinute: 8 * 60,
  endMinute: 8 * 60 + 45,
  weekdays: const {DateTime.monday},
  intervalWeeks: 1,
  validFromLocalDate: DateTime(2026, 9, 7),
  validUntilLocalDate: DateTime(2026, 12, 20),
);
