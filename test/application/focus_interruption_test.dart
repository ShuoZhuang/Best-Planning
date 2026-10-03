// FR-STAT-06 的「常见中断」来源：专注被暂停。
//
// 此前这条链路的写入方根本不存在，因此统计页那一行永远是"暂无记录"（W5）。本文件钉住三件事：
// 暂停**确实**记一次、**重复暂停不重复计数**（`pause()` 在已是暂停态时提前返回）、以及
// **没有装配回调时不报错**（计时器在统计不可用时照常工作）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/interruption_reason.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

final _start = DateTime.utc(2026, 10, 5, 9);

final class _Clock implements Clock {
  _Clock(this._now);
  DateTime _now;
  void advance(Duration duration) => _now = _now.add(duration);
  @override
  DateTime nowUtc() => _now;
}

final class _Monotonic implements MonotonicClock {
  Duration _value = Duration.zero;
  void advance(Duration duration) => _value += duration;
  @override
  Duration now() => _value;
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'session-${++_count}';
}

final class _Store implements FocusEntryStore {
  final saved = <FocusSession>[];
  @override
  Future<FocusSession?> findOpen() async => null;
  @override
  Future<void> save(FocusSession session) async => saved.add(session);
  @override
  Future<List<FocusSession>> confirmedEntries() async => const [];
}

void main() {
  late _Clock clock;
  late _Monotonic monotonic;
  late _Store store;
  late List<FocusSession> interrupted;
  late List<InterruptionReason?> reasons;

  FocusService build({bool withCallback = true}) => FocusService(
    store: store,
    clock: clock,
    monotonicClock: monotonic,
    idGenerator: _Ids(),
    onInterrupted: withCallback
        ? (session, reason) {
            interrupted.add(session);
            reasons.add(reason);
          }
        : null,
  );

  setUp(() {
    clock = _Clock(_start);
    monotonic = _Monotonic();
    store = _Store();
    interrupted = [];
    reasons = [];
  });

  test('暂停记录一次中断，并带上这次专注的任务 id', () async {
    final service = build();
    await service.start('task-1');
    monotonic.advance(const Duration(minutes: 25));
    clock.advance(const Duration(minutes: 25));

    await service.pause();

    expect(interrupted, hasLength(1));
    // 任务 id 会作为事件的 entityId 落到 change_log：没有它，中断就无法与任务对应。
    expect(interrupted.single.taskId, 'task-1');
  });

  test('重复暂停不重复计数', () async {
    final service = build();
    await service.start('task-1');
    await service.pause();
    // `pause()` 在已是暂停态时直接返回，因此这里的第二次调用不该再记一次——否则用户连点
    // 两下就会在统计里凭空多出一次中断。
    await service.pause();

    expect(interrupted, hasLength(1));
  });

  test('继续后再暂停会再记一次（两次中断是两件事）', () async {
    final service = build();
    await service.start('task-1');
    await service.pause();
    await service.resume();
    await service.pause();

    expect(interrupted, hasLength(2));
  });

  test('未装配回调时照常计时（统计不可用不该影响专注）', () async {
    final service = build(withCallback: false);
    await service.start('task-1');

    final paused = await service.pause();

    expect(paused.phase, FocusPhase.paused);
    expect(interrupted, isEmpty);
  });

  group('按原因分类', () {
    test('用户选的原因被原样带出来', () async {
      final service = build();
      await service.start('task-1');

      await service.pause(reason: InterruptionReason.message);
      await service.resume();
      await service.pause(reason: InterruptionReason.interruptedByOthers);

      expect(reasons, <InterruptionReason?>[
        InterruptionReason.message,
        InterruptionReason.interruptedByOthers,
      ]);
    });

    test('没有选原因时仍然记一次中断，只是原因是空的', () async {
      // **这一条是本项的关键**：按原因分类不得让"跳过"变成"不计数"。若实现成
      // "没有原因就不记"，统计里的中断总数会凭空减少，那比只有一种 code 更糟。
      final service = build();
      await service.start('task-1');

      await service.pause();

      expect(interrupted, hasLength(1));
      expect(reasons, <InterruptionReason?>[null]);
    });

    test('两个不同的原因在统计里是两个不同的 code', () {
      // code 就是标签本身（统计页直接显示它），因此分类要成立，标签必须两两不同。
      final labels = [
        for (final reason in InterruptionReason.choices) reason.label,
      ];
      expect(labels.toSet(), hasLength(labels.length));
      expect(labels, isNot(contains(InterruptionReason.neutralLabel)));
    });

    test('枚举名与标签都不是空串（改名成空标签会让统计里出现空白行）', () {
      for (final reason in InterruptionReason.choices) {
        expect(reason.label.trim(), isNotEmpty);
        expect(reason.name.trim(), isNotEmpty);
      }
    });
  });
}
