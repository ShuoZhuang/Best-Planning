// FR-FOCUS-02：程序异常退出后的恢复提示**在真实页面路径上**可达。
//
// 此前 `FocusRecoveryDialog` 的自身行为有测试（`recovery_dialog_test.dart`），服务侧的
// `recoverOpenEntry()`／`confirmRecovery()`／`discardRecovery()` 也有测试，但**没有任何
// 地方弹这个对话框**——`FocusPage` 没有 `initState`，因此异常退出的记录永远不会被处理
// （见 §13.0 的 W10）。本文件钉住的正是这一环：进入专注页即提示，并把用户填写的值落到存储。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';
import 'package:personal_planner/features/focus/focus_page.dart';

final class _Store implements FocusEntryStore {
  _Store(this.open);

  FocusSession? open;
  final saved = <FocusSession>[];

  @override
  Future<void> save(FocusSession session) async {
    saved.add(session);
    open = session;
  }

  @override
  Future<FocusSession?> findOpen() async => open;

  @override
  Future<List<FocusSession>> confirmedEntries() async => saved
      .where((session) => session.recoveryState == FocusRecoveryState.confirmed)
      .toList();
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 10);
}

final class _Ids implements IdGenerator {
  @override
  String next() => 'focus-new';
}

FocusSession _openSession() => FocusSession(
  id: 'focus-1',
  taskId: 'task-1',
  startedAtUtc: DateTime.utc(2026, 10, 2, 9),
  lastWallAtUtc: DateTime.utc(2026, 10, 2, 9, 10),
  phase: FocusPhase.running,
  activeDuration: const Duration(minutes: 10),
  recoveryState: FocusRecoveryState.none,
);

void main() {
  Future<FocusService> pumpPage(WidgetTester tester, _Store store) async {
    final service = FocusService(
      store: store,
      clock: _Clock(),
      monotonicClock: CallbackMonotonicClock(() => Duration.zero),
      idGenerator: _Ids(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusPage(
            service: service,
            taskId: 'task-1',
            taskTitle: '写方案',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('进入专注页即提示确认上次未结束的计时', (tester) async {
    final store = _Store(_openSession());
    await pumpPage(tester, store);

    // 没有这一步，异常退出的记录会无声地停在 needsConfirmation。
    expect(find.text('需要确认本次专注'), findsOneWidget);
  });

  testWidgets('确认后写入已确认状态与用户填写的实际时长', (tester) async {
    final store = _Store(_openSession());
    await pumpPage(tester, store);

    await tester.enterText(find.byKey(const Key('recovery-end-time')), '09:25');
    await tester.enterText(
      find.byKey(const Key('recovery-actual-minutes')),
      '25',
    );
    await tester.tap(find.text('确认并计入统计'));
    await tester.pumpAndSettle();

    expect(store.saved.last.recoveryState, FocusRecoveryState.confirmed);
    expect(store.saved.last.activeDuration.inMinutes, 25);
  });

  testWidgets('选择不计入后写入已丢弃状态', (tester) async {
    final store = _Store(_openSession());
    await pumpPage(tester, store);

    await tester.tap(find.text('不计入本次'));
    await tester.pumpAndSettle();

    expect(store.saved.last.recoveryState, FocusRecoveryState.discarded);
  });

  testWidgets('没有未结束记录时不提示', (tester) async {
    final store = _Store(null);
    await pumpPage(tester, store);

    // 宁可不显示，也不要凭空弹一个"需要确认"。
    expect(find.text('需要确认本次专注'), findsNothing);
  });
}
