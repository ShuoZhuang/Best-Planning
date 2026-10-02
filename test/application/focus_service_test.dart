import 'package:fake_async/fake_async.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/data/database/app_database.dart'
    show AppDatabase;
import 'package:personal_planner/data/repositories/drift_focus_entry_store.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

void main() {
  test('运行、暂停、继续和完成按状态机持久化且重复点击幂等', () {
    fakeAsync((async) {
      final wall = _WallClock(() => async.elapsed);
      final store = _Store();
      final service = FocusService(
        store: store,
        clock: wall,
        monotonicClock: CallbackMonotonicClock(() => async.elapsed),
        idGenerator: _Ids(),
      );

      FocusSession? started;
      service.start('task-1').then((value) => started = value);
      async.flushMicrotasks();
      expect(started?.phase, FocusPhase.running);
      final firstId = started!.id;

      FocusSession? duplicateStart;
      service.start('task-1').then((value) => duplicateStart = value);
      async.flushMicrotasks();
      expect(duplicateStart?.id, firstId);

      async.elapse(const Duration(minutes: 25));
      FocusSession? paused;
      service.pause().then((value) => paused = value);
      async.flushMicrotasks();
      expect(paused?.phase, FocusPhase.paused);
      expect(paused?.activeMinutes, 25);

      FocusSession? duplicatePause;
      service.pause().then((value) => duplicatePause = value);
      async.flushMicrotasks();
      expect(duplicatePause?.activeMinutes, 25);

      service.resume();
      async.flushMicrotasks();
      service.resume();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 20));

      FocusSession? finished;
      service.finish(note: '完成了主要部分').then((value) => finished = value);
      async.flushMicrotasks();
      expect(finished?.phase, FocusPhase.finished);
      expect(finished?.activeMinutes, 45);
      expect(finished?.note, '完成了主要部分');

      FocusSession? duplicateFinish;
      service.finish().then((value) => duplicateFinish = value);
      async.flushMicrotasks();
      expect(duplicateFinish?.id, firstId);
      expect(
        store.saved.map((item) => item.phase),
        contains(FocusPhase.finished),
      );
    });
  });

  test('非法状态转换被拒绝，写入失败时内存状态不提前变化', () async {
    final store = _Store();
    final service = FocusService(
      store: store,
      clock: _WallClock(() => Duration.zero),
      monotonicClock: CallbackMonotonicClock(() => Duration.zero),
      idGenerator: _Ids(),
    );

    await expectLater(
      service.pause(),
      throwsA(isA<FocusTransitionException>()),
    );
    await service.start('task-1');
    store.failNextSave = true;
    await expectLater(service.pause(), throwsA(isA<StateError>()));
    expect(service.current?.phase, FocusPhase.running);
  });

  test('重启发现 running 记录时要求确认，时钟跳变不直接计入', () async {
    final store = _Store(
      open: FocusSession(
        id: 'focus-1',
        taskId: 'task-1',
        startedAtUtc: DateTime.utc(2026, 10, 2, 9),
        lastWallAtUtc: DateTime.utc(2026, 10, 2, 9),
        phase: FocusPhase.running,
        activeDuration: const Duration(minutes: 10),
        recoveryState: FocusRecoveryState.none,
      ),
    );
    final service = FocusService(
      store: store,
      clock: _FixedClock(DateTime.utc(2026, 10, 2, 10)),
      monotonicClock: CallbackMonotonicClock(() => Duration.zero),
      idGenerator: _Ids(),
    );

    final request = await service.recoverOpenEntry();

    expect(request, isNotNull);
    expect(request!.requiresConfirmation, isTrue);
    expect(request.wallClockDriftDetected, isTrue);
    expect(await store.confirmedEntries(), isEmpty);
    expect(store.open?.activeMinutes, 10);

    await service.confirmRecovery(
      endedAtUtc: DateTime.utc(2026, 10, 2, 9, 50),
      actualMinutes: 45,
      note: '已核对',
    );
    final confirmed = await store.confirmedEntries();
    expect(confirmed, hasLength(1));
    expect(confirmed.single.activeMinutes, 45);
    expect(confirmed.single.recoveryState, FocusRecoveryState.confirmed);
  });

  test('Drift 存储只向统计返回已确认记录', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    await database.customInsert("""
      INSERT INTO tasks
        (id, title, notes, priority, estimated_minutes, remaining_minutes,
         energy_level, split_mode, min_chunk_minutes, max_chunk_minutes,
         status, created_at_utc, updated_at_utc)
      VALUES
        ('task-1', '任务', '', 'medium', 60, 60, 'medium', 'splittable',
         30, 90, 'inbox', 1, 1)
      """);
    final store = DriftFocusEntryStore(database);
    final running = FocusSession(
      id: 'focus-db',
      taskId: 'task-1',
      startedAtUtc: DateTime.utc(2026, 10, 2, 9),
      lastWallAtUtc: DateTime.utc(2026, 10, 2, 9, 10),
      phase: FocusPhase.running,
      activeDuration: const Duration(minutes: 10),
      recoveryState: FocusRecoveryState.needsConfirmation,
    );
    await store.save(running);

    expect((await store.findOpen())?.id, 'focus-db');
    expect(await store.confirmedEntries(), isEmpty);

    await store.save(
      running.copyWith(
        phase: FocusPhase.finished,
        endedAtUtc: DateTime.utc(2026, 10, 2, 9, 45),
        activeDuration: const Duration(minutes: 45),
        recoveryState: FocusRecoveryState.confirmed,
        note: '已核对',
      ),
    );

    expect(await store.findOpen(), isNull);
    final confirmed = await store.confirmedEntries();
    expect(confirmed, hasLength(1));
    expect(confirmed.single.activeMinutes, 45);
    expect(confirmed.single.note, '已核对');
  });
}

final class _Store implements FocusEntryStore {
  _Store({this.open});

  FocusSession? open;
  final List<FocusSession> saved = [];
  bool failNextSave = false;

  @override
  Future<List<FocusSession>> confirmedEntries() async => saved
      .where((item) => item.recoveryState == FocusRecoveryState.confirmed)
      .toList();

  @override
  Future<FocusSession?> findOpen() async => open;

  @override
  Future<void> save(FocusSession session) async {
    if (failNextSave) {
      failNextSave = false;
      throw StateError('save failed');
    }
    saved.add(session);
    open = session.phase == FocusPhase.finished ? null : session;
  }
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'focus-1';
}

final class _WallClock implements Clock {
  _WallClock(this.elapsed);
  final Duration Function() elapsed;
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 9).add(elapsed());
}

final class _FixedClock implements Clock {
  const _FixedClock(this.value);
  final DateTime value;
  @override
  DateTime nowUtc() => value;
}
