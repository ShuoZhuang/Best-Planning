// W6/FR-PREF：偏好学习的闭环。
//
// 这一项此前两端都断：`PreferenceEvidence` 在 `lib/` 中零构造（没有任何代码写证据），
// 且 `PreferenceService.refresh(evidence)` 没有任何生产调用方（全库只有测试调用）。
// 因此最关键的断言不是"仓储能存能取"，而是**走完整条链之后分析器真的产出了建议**——
// 在这之前，无论用多久，偏好页都只会是一份空名单。
//
// 注意分析器按 `observedAtUtc` 的**不同天数**计数（至少 20 条、跨 14 天），而记录器用的是
// "此刻"作为观察时刻（观察发生在专注结束时），因此这里的时钟要跨天推进，而不是伪造
// 会话的开始时间。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_evidence_recorder.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/application/preference_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_preference_evidence_repository.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

final class _MutableClock implements Clock {
  _MutableClock(this.value);
  DateTime value;
  @override
  DateTime nowUtc() => value;
}

final class _Ids implements IdGenerator {
  var _value = 0;
  @override
  String next() => 'e-${++_value}';
}

final class _Tasks implements TaskRepository {
  _Tasks(this.tasks);
  final Map<String, PlannerTask> tasks;

  @override
  Future<PlannerTask?> getById(String id) async => tasks[id];

  @override
  Future<void> save(PlannerTask task) async => tasks[task.id] = task;

  @override
  Stream<List<PlannerTask>> watchAllTasks() async* {
    yield const [];
  }

  @override
  Stream<List<PlannerTask>> watchOpenTasks() async* {
    yield const [];
  }
}

final class _Workspace implements WorkspaceRepository {
  const _Workspace({this.projects = const []});
  final List<PlannerProject> projects;

  @override
  Future<List<PlannerArea>> listAreas() async => const [];

  @override
  Future<List<PlannerProject>> listProjects() async => projects;

  @override
  Future<void> saveArea(PlannerArea area) async {}

  @override
  Future<void> saveProject(PlannerProject project) async {}
}

final _created = DateTime.utc(2026, 9, 1);

PlannerTask _task({String? projectId}) => PlannerTask(
  id: 'task-1',
  title: '写方案',
  priority: TaskPriority.medium,
  estimatedMinutes: 60,
  remainingMinutes: 60,
  projectId: projectId,
  energyLevel: TaskEnergyLevel.medium,
  splitMode: TaskSplitMode.splittable,
  minChunkMinutes: 30,
  maxChunkMinutes: 60,
  status: TaskStatus.open,
  createdAtUtc: _created,
  updatedAtUtc: _created,
);

PlannerProject _project() => PlannerProject(
  id: 'project-1',
  areaId: 'area-1',
  name: '论文',
  createdAtUtc: _created,
  updatedAtUtc: _created,
);

FocusSession _session({
  required String id,
  required DateTime startedAtUtc,
  required int minutes,
}) => FocusSession(
  id: id,
  taskId: 'task-1',
  startedAtUtc: startedAtUtc,
  lastWallAtUtc: startedAtUtc,
  endedAtUtc: startedAtUtc.add(Duration(minutes: minutes)),
  phase: FocusPhase.finished,
  activeDuration: Duration(minutes: minutes),
  recoveryState: FocusRecoveryState.confirmed,
);

void main() {
  late AppDatabase database;
  late _MutableClock clock;
  late DriftPreferenceEvidenceRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    clock = _MutableClock(DateTime.utc(2026, 9, 1, 10));
    repository = DriftPreferenceEvidenceRepository(database);
  });

  tearDown(() => database.close());

  FocusEvidenceRecorder recorderFor(WorkspaceRepository workspace) =>
      FocusEvidenceRecorder(
        evidence: repository,
        tasks: _Tasks({'task-1': _task(projectId: 'project-1')}),
        workspace: workspace,
        zones: TimeZoneDatabase(),
        // 固定时区让"上午/下午"由会话开始时刻唯一决定。
        timeZoneId: 'UTC',
        clock: clock,
        idGenerator: _Ids(),
      );

  test('证据仓储按观察时刻存取，元数据与数值原样往返', () async {
    await repository.save(
      PreferenceEvidence(
        id: 'e-1',
        kind: PreferenceEvidenceKind.focusCompletion,
        subjectKey: 'area:area-1',
        observedAtUtc: DateTime.utc(2026, 9, 3, 10),
        numericValue: 45,
        metadata: const {'timeBucket': 'morning', 'minutes': 45},
      ),
    );

    final all = await repository.since(DateTime.utc(2026, 1, 1));
    expect(all, hasLength(1));
    expect(all.single.kind, PreferenceEvidenceKind.focusCompletion);
    expect(all.single.subjectKey, 'area:area-1');
    expect(all.single.numericValue, 45);
    expect(all.single.specialDay, isFalse);
    expect(all.single.metadata['timeBucket'], 'morning');

    // 窗口过滤：这条证据不该出现在更晚的起点之后。
    expect(await repository.since(DateTime.utc(2026, 9, 4)), isEmpty);
  });

  test('记录器按任务所属领域归组，并带上实际专注分钟与时段', () async {
    clock.value = DateTime.utc(2026, 9, 5, 10);
    final recorder = recorderFor(_Workspace(projects: [_project()]));

    final written = await recorder.recordCompletedFocus(
      _session(
        id: 's-1',
        startedAtUtc: DateTime.utc(2026, 9, 5, 9),
        minutes: 50,
      ),
    );

    expect(written, isTrue);
    final evidence = (await repository.since(DateTime.utc(2026, 1, 1))).single;
    // subjectKey 取领域而不是任务：分析器要求同一主体至少 20 条、跨 14 天，
    // 按任务分组现实中几乎永远攒不够。
    expect(evidence.subjectKey, 'area:area-1');
    // FR-PREF-01 的"实际专注长度"。
    expect(evidence.numericValue, 50);
    expect(evidence.metadata['timeBucket'], 'morning');
    expect(evidence.observedAtUtc, clock.value);
  });

  test('归属不到领域的任务不写证据', () async {
    // 没有项目就没有领域，也就没有可归组的主体：凭空写一条会把不同性质的行为混在一起。
    final recorder = recorderFor(const _Workspace());
    final written = await recorder.recordCompletedFocus(
      _session(
        id: 's-1',
        startedAtUtc: DateTime.utc(2026, 9, 5, 9),
        minutes: 50,
      ),
    );

    expect(written, isFalse);
    expect(await repository.since(DateTime.utc(2026, 1, 1)), isEmpty);
  });

  group('FR-PREF-07 特殊日排除', () {
    // 此前记录器**硬编码 `specialDay: false`**，而分析器里
    // `evidence.where((item) => !item.specialDay)` 那条排除逻辑一直都在——于是它永远筛不掉
    // 任何东西。下面三条把这个信号钉住，否则"结构就绪、数据恒为常量"会再次发生。
    test('回调说这天是特殊日时，证据被标为特殊日', () async {
      final recorder = FocusEvidenceRecorder(
        evidence: repository,
        tasks: _Tasks({'task-1': _task(projectId: 'project-1')}),
        workspace: _Workspace(projects: [_project()]),
        zones: TimeZoneDatabase(),
        timeZoneId: 'UTC',
        clock: clock,
        idGenerator: _Ids(),
        isSpecialDay: (date) async => date == DateTime(2026, 9, 5),
      );

      await recorder.recordCompletedFocus(
        _session(
          id: 's-1',
          startedAtUtc: DateTime.utc(2026, 9, 5, 9),
          minutes: 50,
        ),
      );

      final all = await repository.since(DateTime.utc(2026, 1, 1));
      expect(all.single.specialDay, isTrue);
    });

    test('判定用的是**会话开始的那个本地日**，不是"今天"', () async {
      // 时钟停在 9-06，而会话开始于 9-05：若实现里用了 `clock.nowUtc()` 的日期，
      // 这条就会失败。
      clock.value = DateTime.utc(2026, 9, 6, 10);
      final seen = <DateTime>[];
      final recorder = FocusEvidenceRecorder(
        evidence: repository,
        tasks: _Tasks({'task-1': _task(projectId: 'project-1')}),
        workspace: _Workspace(projects: [_project()]),
        zones: TimeZoneDatabase(),
        timeZoneId: 'UTC',
        clock: clock,
        idGenerator: _Ids(),
        isSpecialDay: (date) async {
          seen.add(date);
          return false;
        },
      );

      await recorder.recordCompletedFocus(
        _session(
          id: 's-1',
          startedAtUtc: DateTime.utc(2026, 9, 5, 9),
          minutes: 50,
        ),
      );

      expect(seen, <DateTime>[DateTime(2026, 9, 5)]);
    });

    test('没有装配回调时按普通日记录（既有行为不变）', () async {
      final recorder = recorderFor(_Workspace(projects: [_project()]));

      await recorder.recordCompletedFocus(
        _session(
          id: 's-1',
          startedAtUtc: DateTime.utc(2026, 9, 5, 9),
          minutes: 50,
        ),
      );

      final all = await repository.since(DateTime.utc(2026, 1, 1));
      expect(all.single.specialDay, isFalse);
    });
  });

  test('走完整条链后分析器真的产出建议', () async {
    final recorder = recorderFor(_Workspace(projects: [_project()]));

    // 20 次专注、跨 14 天，上午的时长明显长于晚上。
    for (var index = 0; index < 20; index++) {
      clock.value = DateTime.utc(2026, 9, index % 14 + 1, 20);
      final morning = index.isEven;
      await recorder.recordCompletedFocus(
        _session(
          id: 's-$index',
          startedAtUtc: DateTime.utc(2026, 9, index % 14 + 1, morning ? 9 : 19),
          minutes: morning ? 50 : 10,
        ),
      );
    }

    final service = PreferenceService(
      analyzer: const RuleBasedPreferenceAnalyzer(),
      store: MemoryPreferenceStore(),
    );
    final suggestions = await service.refresh(
      await repository.since(DateTime.utc(2026, 1, 1)),
    );

    // 这正是"输入端与触发端都断"的时期里不可能出现的结果。
    expect(suggestions, isNotEmpty);
    expect(suggestions.single.id, startsWith('time:area:area-1'));
    expect(suggestions.single.evidenceCount, 20);
    expect(suggestions.single.activeDayCount, 14);
  });

  test('专注服务在结束时把证据交出去，且回调失败不影响计时结果', () async {
    final sessions = <FocusSession>[];
    final service = FocusService(
      store: _MemoryFocusStore(),
      clock: clock,
      monotonicClock: CallbackMonotonicClock(() => Duration.zero),
      idGenerator: _Ids(),
      onFinished: (session) async {
        sessions.add(session);
        throw StateError('证据写入失败不该让"完成"看起来失败');
      },
    );

    await service.start('task-1');
    final finished = await service.finish();

    expect(finished.phase, FocusPhase.finished);
    expect(sessions.single.id, finished.id);
  });
}

final class _MemoryFocusStore implements FocusEntryStore {
  FocusSession? _open;

  @override
  Future<FocusSession?> findOpen() async => _open;

  @override
  Future<void> save(FocusSession session) async => _open = session;

  @override
  Future<List<FocusSession>> confirmedEntries() async => const [];
}
