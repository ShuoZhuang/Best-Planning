// Task 10（课程编辑完整性修复计划 §2.6）：**导入记录页**。
//
// 这一页存在的唯一理由是"撤销导入不能只活在一条会消失的提示条上"（计划 §1.10）。
// 因此本文件钉住四件事：
//
// 1. **四态**：加载、空、错误、正常——错误态要有可读说明与重试；
// 2. **不泄露内部标识**：界面上不出现批次 id、图片哈希或数据库异常；
// 3. **按钮状态由仓储事实决定**：已撤销不可再撤销、一条不剩的 partial 只给"重新导入"；
// 4. **受保护批次必须先二次确认**，取消时**零写入**（H2）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/timetable_import_service.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/design/planner_localization.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';
import 'package:personal_planner/domain/repositories/timetable_import_repository.dart';
import 'package:personal_planner/features/calendar/timetable_import/timetable_import_history_page.dart';

void main() {
  late _ImportRepository repository;
  late TimetableImportService service;

  setUp(() {
    repository = _ImportRepository();
    service = TimetableImportService(
      calendarRepository: const _NoCalendar(),
      zones: TimeZoneDatabase(),
      importRepository: repository,
    );
  });

  Future<void> pump(
    WidgetTester tester, {
    VoidCallback? onImportTimetable,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: PlannerLocalization.locale,
        localizationsDelegates: PlannerLocalization.delegates,
        supportedLocales: PlannerLocalization.supportedLocales,
        home: Scaffold(
          body: TimetableImportHistoryPage(
            service: service,
            onImportTimetable: onImportTimetable,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TimetableImportHistoryItem item({
    required String batchId,
    String fileName = 'schedule.png',
    TimetableImportBatchStatus status = TimetableImportBatchStatus.committed,
    int created = 3,
    int remaining = 3,
    int protectedCount = 0,
    bool canRollback = true,
    DateTime? createdAt,
  }) => TimetableImportHistoryItem(
    batchId: batchId,
    sourceFileName: fileName,
    termId: 'term-autumn',
    termName: '2026 秋季学期',
    createdAtUtc: createdAt ?? DateTime.utc(2026, 10, 5, 2),
    createdSeriesCount: created,
    remainingSeriesCount: remaining,
    protectedSeriesCount: protectedCount,
    status: status,
    canRollback: canRollback,
    requiresForceConfirmation: protectedCount > 0,
  );

  testWidgets('空态：说明"还没有记录"，并给出导入入口', (tester) async {
    var importTapped = 0;
    await pump(tester, onImportTimetable: () => importTapped++);

    expect(find.byKey(const Key('import-history-empty')), findsOneWidget);
    await tester.tap(find.byKey(const Key('import-history-import')));
    await tester.pumpAndSettle();
    expect(importTapped, 1);
  });

  testWidgets('错误态：给用户可读说明与「重试」，不显示异常文本', (tester) async {
    repository.failListHistory = true;
    await pump(tester);

    expect(find.byKey(const Key('import-history-error')), findsOneWidget);
    expect(find.byKey(const Key('import-history-retry')), findsOneWidget);
    expect(
      find.textContaining('Exception'),
      findsNothing,
      reason: '错误文案不得包含异常 toString（规范全局不变量第 7 条）',
    );

    repository.failListHistory = false;
    repository.items = [item(batchId: 'batch-1')];
    await tester.tap(find.byKey(const Key('import-history-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-history-list')), findsOneWidget);
  });

  testWidgets('正常态：四种状态各自一句文案，且**不显示批次 id**', (tester) async {
    repository.items = [
      item(batchId: 'batch-committed'),
      item(
        batchId: 'batch-modified',
        protectedCount: 2,
        fileName: 'modified.png',
      ),
      item(
        batchId: 'batch-partial',
        status: TimetableImportBatchStatus.partiallyDeleted,
        remaining: 1,
      ),
      item(
        batchId: 'batch-rolled',
        status: TimetableImportBatchStatus.rolledBack,
        remaining: 0,
        canRollback: false,
      ),
    ];
    await pump(tester);

    // 状态文案嵌在副标题里（文件名、学期、计数也在同一段），因此用 contains 断言。
    expect(find.textContaining('已导入'), findsOneWidget);
    expect(find.textContaining('导入后有修改'), findsOneWidget);
    expect(find.textContaining('已删除部分课程，可重新导入'), findsOneWidget);
    expect(find.textContaining('已撤销'), findsOneWidget);
    for (final id in [
      'batch-committed',
      'batch-modified',
      'batch-partial',
      'batch-rolled',
    ]) {
      expect(
        find.textContaining(id),
        findsNothing,
        reason: '批次 id 只供动作调用，不直接显示给用户',
      );
    }
  });

  testWidgets('H4：已撤销的行**没有**撤销按钮', (tester) async {
    repository.items = [
      item(
        batchId: 'batch-rolled',
        status: TimetableImportBatchStatus.rolledBack,
        canRollback: false,
      ),
    ];
    await pump(tester);

    expect(
      find.byKey(const Key('import-history-rollback-batch-rolled')),
      findsNothing,
    );
  });

  testWidgets('一条不剩的 partiallyDeleted 只给「重新导入课表」', (tester) async {
    var importTapped = 0;
    repository.items = [
      item(
        batchId: 'batch-empty',
        status: TimetableImportBatchStatus.partiallyDeleted,
        remaining: 0,
        canRollback: false,
      ),
    ];
    await pump(tester, onImportTimetable: () => importTapped++);

    expect(
      find.byKey(const Key('import-history-rollback-batch-empty')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('import-history-reimport-batch-empty')),
    );
    await tester.pumpAndSettle();
    expect(importTapped, 1);
  });

  testWidgets('H2：受保护批次撤销前必须二次确认；取消 ⇒ 零写入', (tester) async {
    repository.items = [item(batchId: 'batch-1', protectedCount: 2)];
    repository.protectedEventIds = {'evt-a', 'evt-b'};
    await pump(tester);

    await tester.tap(find.byKey(const Key('import-history-rollback-batch-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('import-rollback-confirm')), findsOneWidget);

    await tester.tap(find.byKey(const Key('import-rollback-cancel')));
    await tester.pumpAndSettle();
    expect(repository.rollbackCalls, isEmpty, reason: '未确认时不许有任何写入');
  });

  testWidgets('H2：确认之后按 force 集合回滚，并刷新列表', (tester) async {
    repository.items = [item(batchId: 'batch-1', protectedCount: 1)];
    repository.protectedEventIds = {'evt-a'};
    repository.afterRollback = [
      item(
        batchId: 'batch-1',
        status: TimetableImportBatchStatus.rolledBack,
        remaining: 0,
        canRollback: false,
      ),
    ];
    await pump(tester);

    await tester.tap(find.byKey(const Key('import-history-rollback-batch-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('import-rollback-force')));
    await tester.pumpAndSettle();

    expect(repository.rollbackCalls, hasLength(1));
    expect(repository.rollbackCalls.single.$1, 'batch-1');
    expect(repository.rollbackCalls.single.$2, {
      'evt-a',
    }, reason: '历史页与提示条必须传同一套 force 集合');
    // 刷新之后那一行变成"已撤销"且没有撤销按钮（提示条上还有一句含"已撤销"的文案，
    // 因此这里是 findsWidgets）。
    expect(find.textContaining('已撤销'), findsWidgets);
    expect(
      find.byKey(const Key('import-history-rollback-batch-1')),
      findsNothing,
    );
  });

  testWidgets('没有保护课程时直接撤销，不弹确认框', (tester) async {
    repository.items = [item(batchId: 'batch-1')];
    await pump(tester);

    await tester.tap(find.byKey(const Key('import-history-rollback-batch-1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('import-rollback-confirm')), findsNothing);
    expect(repository.rollbackCalls, hasLength(1));
    expect(repository.rollbackCalls.single.$2, isEmpty);
  });
}

final class _ImportRepository implements TimetableImportRepository {
  List<TimetableImportHistoryItem> items = const [];
  List<TimetableImportHistoryItem>? afterRollback;
  Set<String> protectedEventIds = const {};
  bool failListHistory = false;
  final List<(String, Set<String>)> rollbackCalls = [];

  @override
  Future<List<TimetableImportHistoryItem>> listHistory({
    String? termId,
    bool includeRolledBack = true,
  }) async {
    if (failListHistory) {
      throw StateError('数据库炸了：路径 G:\\private\\planner.sqlite');
    }
    return items;
  }

  @override
  Future<RollbackPreview> inspectRollback(String batchId) async =>
      RollbackPreview(
        batchId: batchId,
        eventIds: {for (final id in protectedEventIds) id},
        protectedEventIds: protectedEventIds,
      );

  @override
  Future<RollbackResult> rollback(
    String batchId, {
    Set<String> forceEventIds = const {},
  }) async {
    rollbackCalls.add((batchId, forceEventIds));
    if (afterRollback case final next?) items = next;
    return RollbackResult(batchId: batchId, deletedEventCount: 2);
  }

  @override
  Future<TimetableImportBatch> commit(TimetableImportCommit request) =>
      throw UnimplementedError();
}

final class _NoCalendar implements CalendarRepository {
  const _NoCalendar();

  @override
  Future<List<CalendarOccurrence>> occurrencesBetween(
    DateTime startUtc,
    DateTime endUtc,
  ) async => const [];

  @override
  Future<void> save(CalendarEvent event) async {}
}

/// `TimeRange` 只用于让上面那个 `_NoCalendar` 的返回类型可解析。
// ignore: unused_element
final _unusedRange = TimeRange(
  startUtc: DateTime.utc(2026),
  endUtc: DateTime.utc(2026, 1, 2),
);
