// W5：三类统计事件里"建议采纳行为"的来源。
//
// 此前 `change_log` 只有计划生命周期事件（`undo:`／`confirm`／`create`），而统计侧读的是
// `suggestion:`／`replan:`／`interruption:` 三类**行为**事件，两侧一处都对不上，因此
// "建议采纳行为"结构上恒为零。这里验证它真的有了来源：事件写进去，统计**读得出来**。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/analytics_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/database/daos/analytics_dao.dart';
import 'package:personal_planner/data/repositories/drift_calendar_repository.dart';
import 'package:personal_planner/data/repositories/drift_analytics_event_log.dart';
import 'package:personal_planner/domain/models/analytics.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/features/settings/preferences/preferences_page.dart';

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'event-${++_value}';
}

void main() {
  late AppDatabase database;
  late DriftAnalyticsEventLog log;

  final start = DateTime.utc(2026, 10, 1);
  final end = DateTime.utc(2026, 10, 8);

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    log = DriftAnalyticsEventLog(database, idGenerator: _Ids());
  });

  tearDown(() => database.close());

  Future<AnalyticsReport> report() => AnalyticsService(
    source: AnalyticsDao(database, calendar: DriftCalendarRepository(database)),
  ).query(AnalyticsFilter(startUtc: start, endUtc: end));

  test('建议事件写进去之后统计读得出来（此前恒为零）', () async {
    final at = DateTime.utc(2026, 10, 3, 9);
    await log.record(
      kind: AnalyticsEventKind.suggestion,
      code: 'accepted',
      observedAtUtc: at,
      entityId: 'suggestion-1',
    );
    await log.record(
      kind: AnalyticsEventKind.suggestion,
      code: 'accepted',
      observedAtUtc: at,
      entityId: 'suggestion-2',
    );
    await log.record(
      kind: AnalyticsEventKind.suggestion,
      code: 'rejected',
      observedAtUtc: at,
      entityId: 'suggestion-3',
    );

    final behavior = (await report()).suggestionBehavior;

    expect(behavior.accepted, 2);
    expect(behavior.rejected, 1);
    expect(behavior.modified, 0);
    // 采纳率的分母是三种动作之和：这正是"建议采纳行为"这项统计的口径。
    expect(behavior.acceptanceRate.denominator, 3);
  });

  test('窗口之外的同一事件不计入', () async {
    // 读取端按 `changedAtUtc` 过滤，写入端必须写入**观察到**的时刻而不是当前时刻，
    // 否则回填或跨窗口的行为会被算到错误的一天。
    await log.record(
      kind: AnalyticsEventKind.suggestion,
      code: 'accepted',
      observedAtUtc: DateTime.utc(2026, 9, 1),
    );

    expect((await report()).suggestionBehavior.accepted, 0);
  });

  test('空 code 或含冒号的 code 被拒绝，避免统计里出现被截断的词', () async {
    await expectLater(
      log.record(
        kind: AnalyticsEventKind.suggestion,
        code: '',
        observedAtUtc: DateTime.utc(2026, 10, 3),
      ),
      throwsArgumentError,
    );
    await expectLater(
      log.record(
        kind: AnalyticsEventKind.suggestion,
        code: 'accepted:extra',
        observedAtUtc: DateTime.utc(2026, 10, 3),
      ),
      throwsArgumentError,
    );
  });

  testWidgets('在偏好页确认建议会报告 accepted，并由上层写入事件', (tester) async {
    final recorded = <(String, String)>[];
    final service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: MemoryPreferenceStore(),
    );
    await service.refresh(_strongEvidence());

    await tester.pumpWidget(
      MaterialApp(
        home: PreferencesPage(
          service: service,
          onSuggestionAction: (action, id) => recorded.add((action, id)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('确认采用'));
    await tester.pumpAndSettle();

    // 动作与建议 id 都要带出来：统计按动作分档，审计要能追到是哪条建议。
    expect(recorded, hasLength(1));
    expect(recorded.single.$1, 'accepted');
    expect(recorded.single.$2, isNotEmpty);
  });
}

/// 与既有分析器测试同形：同一 subjectKey（`area:study`）20 条、跨 14 天、上下午差异明显，
/// 因此 `refresh` 会真的产出一条建议。
List<PreferenceEvidence> _strongEvidence() => [
  for (var index = 0; index < 20; index++)
    PreferenceEvidence(
      id: 'e-$index',
      kind: PreferenceEvidenceKind.focusCompletion,
      subjectKey: 'area:study',
      observedAtUtc: DateTime.utc(
        2026,
        9,
        index % 14 + 1,
        index.isEven ? 9 : 19,
      ),
      numericValue: index.isEven ? 0.9 : 0.6,
      metadata: {'timeBucket': index.isEven ? 'morning' : 'evening'},
    ),
];
