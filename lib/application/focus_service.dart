import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

enum FocusPhase { running, paused, finished }

enum FocusRecoveryState { none, needsConfirmation, confirmed, discarded }

final class FocusSession {
  const FocusSession({
    required this.id,
    required this.taskId,
    required this.startedAtUtc,
    required this.lastWallAtUtc,
    required this.phase,
    required this.activeDuration,
    required this.recoveryState,
    this.endedAtUtc,
    this.note = '',
  });

  final String id;
  final String taskId;
  final DateTime startedAtUtc;
  final DateTime lastWallAtUtc;
  final DateTime? endedAtUtc;
  final FocusPhase phase;
  final Duration activeDuration;
  final FocusRecoveryState recoveryState;
  final String note;

  int get activeMinutes => activeDuration.inMinutes;

  FocusSession copyWith({
    DateTime? lastWallAtUtc,
    DateTime? endedAtUtc,
    FocusPhase? phase,
    Duration? activeDuration,
    FocusRecoveryState? recoveryState,
    String? note,
  }) => FocusSession(
    id: id,
    taskId: taskId,
    startedAtUtc: startedAtUtc,
    lastWallAtUtc: lastWallAtUtc ?? this.lastWallAtUtc,
    endedAtUtc: endedAtUtc ?? this.endedAtUtc,
    phase: phase ?? this.phase,
    activeDuration: activeDuration ?? this.activeDuration,
    recoveryState: recoveryState ?? this.recoveryState,
    note: note ?? this.note,
  );
}

abstract interface class FocusEntryStore {
  Future<FocusSession?> findOpen();

  Future<void> save(FocusSession session);

  Future<List<FocusSession>> confirmedEntries();
}

final class FocusTransitionException implements Exception {
  const FocusTransitionException(this.message);
  final String message;
  @override
  String toString() => 'FocusTransitionException: $message';
}

final class FocusRecoveryRequest {
  const FocusRecoveryRequest({
    required this.session,
    required this.suggestedEndUtc,
    required this.wallClockDriftDetected,
  });

  final FocusSession session;
  final DateTime suggestedEndUtc;
  final bool wallClockDriftDetected;
  bool get requiresConfirmation => true;
}

final class FocusRecoveryConfirmation {
  const FocusRecoveryConfirmation({
    required this.endedAtUtc,
    required this.actualMinutes,
    this.note = '',
  });

  final DateTime endedAtUtc;
  final int actualMinutes;
  final String note;
}

final class FocusService {
  FocusService({
    required this.store,
    required this.clock,
    required this.monotonicClock,
    required this.idGenerator,
    this.onFinished,
  });

  final FocusEntryStore store;
  final Clock clock;
  final MonotonicClock monotonicClock;
  final IdGenerator idGenerator;

  /// 一次专注正常结束后的回调（FR-PREF-01 的证据来源）。
  ///
  /// 用回调而不是直接依赖偏好模块：计时不该知道偏好学习的存在，装配由组合根负责。
  /// 为空时只计时、不留证据。**刻意只在显式 `finish()` 上触发**——崩溃恢复后确认的那条
  /// 路径不触发，因为用户补录的时长未必反映真实偏好；这一取舍登记在 §13.0。
  final Future<void> Function(FocusSession session)? onFinished;

  FocusSession? _current;
  Duration? _lastMonotonicMark;

  FocusSession? get current => _current;

  Future<FocusSession> start(String taskId) async {
    final existing = _current;
    if (existing != null && existing.phase != FocusPhase.finished) {
      if (existing.taskId == taskId) return existing;
      throw const FocusTransitionException('已有进行中的专注');
    }
    final now = clock.nowUtc();
    final session = FocusSession(
      id: idGenerator.next(),
      taskId: taskId,
      startedAtUtc: now,
      lastWallAtUtc: now,
      phase: FocusPhase.running,
      activeDuration: Duration.zero,
      recoveryState: FocusRecoveryState.none,
    );
    await store.save(session);
    _current = session;
    _lastMonotonicMark = monotonicClock.now();
    return session;
  }

  Future<FocusSession> pause() async {
    final session = _requireCurrent();
    if (session.phase == FocusPhase.paused) return session;
    if (session.phase != FocusPhase.running) {
      throw const FocusTransitionException('只有运行中的专注可暂停');
    }
    final updated = session.copyWith(
      phase: FocusPhase.paused,
      activeDuration: _activeThroughNow(session),
      lastWallAtUtc: clock.nowUtc(),
    );
    await store.save(updated);
    _current = updated;
    _lastMonotonicMark = null;
    return updated;
  }

  Future<FocusSession> resume() async {
    final session = _requireCurrent();
    if (session.phase == FocusPhase.running) return session;
    if (session.phase != FocusPhase.paused) {
      throw const FocusTransitionException('只有暂停的专注可继续');
    }
    final updated = session.copyWith(
      phase: FocusPhase.running,
      lastWallAtUtc: clock.nowUtc(),
    );
    await store.save(updated);
    _current = updated;
    _lastMonotonicMark = monotonicClock.now();
    return updated;
  }

  Future<FocusSession>? _finishing;

  /// 并发调用共享同一个在途 Future。
  ///
  /// `_current` 是在 `await store.save(...)` **之后**才赋值的——这是"写入失败时内存状态
  /// 不提前变化"所要求的既有保证。代价是：并发的第二次 `finish()` 会在那个 await 期间读到
  /// **仍然 running** 的会话，于是 `phase == finished` 这道幂等保护看不到"已结束"，会把结束
  /// 流程走两遍——完成回调因此触发两次，重复写入一条偏好证据（学习分析器按"20 条 / 14 天"
  /// 判定门槛，重复计入会扭曲结论）。
  ///
  /// 共享在途 Future 使"一次结束"只发生一次，且**不动**上面那条保证；`phase == finished`
  /// 的原保护保留给"完成之后再调用"的情形。
  Future<FocusSession> finish({String? note}) {
    final inFlight = _finishing;
    if (inFlight != null) return inFlight;
    final future = _finishOnce(note);
    _finishing = future;
    return future.whenComplete(() {
      // 只在仍是我们这一份时清空：失败或成功后都允许后续调用重新进入，
      // 后续调用会由 `phase == finished` 的保护直接返回，不会再触发回调。
      if (identical(_finishing, future)) _finishing = null;
    });
  }

  Future<FocusSession> _finishOnce(String? note) async {
    final session = _requireCurrent();
    if (session.phase == FocusPhase.finished) return session;
    final now = clock.nowUtc();
    final updated = session.copyWith(
      phase: FocusPhase.finished,
      endedAtUtc: now,
      lastWallAtUtc: now,
      activeDuration: session.phase == FocusPhase.running
          ? _activeThroughNow(session)
          : session.activeDuration,
      recoveryState: FocusRecoveryState.confirmed,
      note: note ?? session.note,
    );
    await store.save(updated);
    _current = updated;
    _lastMonotonicMark = null;
    // 证据留痕不该影响计时结果：回调失败只丢一条证据，不能让"完成"看起来失败。
    final finished = onFinished;
    if (finished != null) {
      try {
        await finished(updated);
      } on Object {
        // 有意吞掉：见上。
      }
    }
    return updated;
  }

  Future<FocusRecoveryRequest?> recoverOpenEntry() async {
    final open = await store.findOpen();
    if (open == null) return null;
    final now = clock.nowUtc();
    final wallElapsed = now.difference(open.lastWallAtUtc);
    final drift =
        wallElapsed.isNegative ||
        wallElapsed.abs() > const Duration(minutes: 5);
    final pending = open.copyWith(
      recoveryState: FocusRecoveryState.needsConfirmation,
    );
    await store.save(pending);
    _current = pending;
    _lastMonotonicMark = null;
    return FocusRecoveryRequest(
      session: pending,
      suggestedEndUtc: now,
      wallClockDriftDetected: drift,
    );
  }

  Future<FocusSession> confirmRecovery({
    required DateTime endedAtUtc,
    required int actualMinutes,
    String note = '',
  }) async {
    final session = _requireCurrent();
    if (session.recoveryState != FocusRecoveryState.needsConfirmation) {
      throw const FocusTransitionException('当前记录无需恢复确认');
    }
    if (!endedAtUtc.isUtc || endedAtUtc.isBefore(session.startedAtUtc)) {
      throw ArgumentError.value(endedAtUtc, 'endedAtUtc');
    }
    if (actualMinutes <= 0) {
      throw ArgumentError.value(actualMinutes, 'actualMinutes');
    }
    final confirmed = session.copyWith(
      phase: FocusPhase.finished,
      endedAtUtc: endedAtUtc,
      lastWallAtUtc: endedAtUtc,
      activeDuration: Duration(minutes: actualMinutes),
      recoveryState: FocusRecoveryState.confirmed,
      note: note,
    );
    await store.save(confirmed);
    _current = confirmed;
    return confirmed;
  }

  Future<FocusSession> discardRecovery() async {
    final session = _requireCurrent();
    if (session.recoveryState != FocusRecoveryState.needsConfirmation) {
      throw const FocusTransitionException('当前记录无需恢复确认');
    }
    final discarded = session.copyWith(
      phase: FocusPhase.finished,
      endedAtUtc: clock.nowUtc(),
      recoveryState: FocusRecoveryState.discarded,
    );
    await store.save(discarded);
    _current = discarded;
    return discarded;
  }

  FocusSession _requireCurrent() {
    final session = _current;
    if (session == null) {
      throw const FocusTransitionException('当前没有专注记录');
    }
    return session;
  }

  Duration _activeThroughNow(FocusSession session) {
    final mark = _lastMonotonicMark;
    if (mark == null) return session.activeDuration;
    final delta = monotonicClock.now() - mark;
    return session.activeDuration + (delta.isNegative ? Duration.zero : delta);
  }
}
