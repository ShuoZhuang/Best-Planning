// FR-STAT-06 的"常见中断"**按原因分类**在真实页面路径上可达。
//
// 服务侧记录原因由 `test/application/focus_interruption_test.dart` 钉住；本文件钉住的是
// **界面那一环**：点"暂停"会先问原因，选中的原因真的被交到服务；"跳过"照样暂停（只是没有
// 原因）；"取消"则什么都不做。三者的差别必须清楚——把"取消"做成"暂停"会让用户误触后
// 计时就停了，而把"跳过"做成"不暂停"会让中断不计数。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/interruption_reason.dart';
import 'package:personal_planner/features/focus/focus_page.dart';
import 'package:personal_planner/platform/monotonic_clock.dart';

final class _Store implements FocusEntryStore {
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
  Future<List<FocusSession>> confirmedEntries() async => const [];
}

final class _Clock implements Clock {
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 2, 10);
}

final class _Ids implements IdGenerator {
  var _count = 0;
  @override
  String next() => 'focus-${++_count}';
}

void main() {
  late _Store store;
  late List<InterruptionReason?> recorded;

  Future<void> pumpRunning(WidgetTester tester) async {
    store = _Store();
    recorded = [];
    final service = FocusService(
      store: store,
      clock: _Clock(),
      monotonicClock: CallbackMonotonicClock(() => Duration.zero),
      idGenerator: _Ids(),
      onInterrupted: (session, reason) => recorded.add(reason),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusPage(service: service, taskId: 'task-1', taskTitle: '写方案'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
  }

  testWidgets('点"暂停"先问原因，选中后把原因交给服务', (tester) async {
    await pumpRunning(tester);

    await tester.tap(find.byKey(const Key('focus-pause')));
    await tester.pumpAndSettle();

    expect(find.text('这次是因为什么暂停？'), findsOneWidget);
    // **问原因时计时还没停**：取消（下面那条）必须能什么都不做。
    expect(recorded, isEmpty);

    await tester.tap(find.byKey(const Key('pause-reason-interruptedByOthers')));
    await tester.pumpAndSettle();

    expect(recorded, <InterruptionReason?>[
      InterruptionReason.interruptedByOthers,
    ]);
    expect(store.open!.phase, FocusPhase.paused);
  });

  testWidgets('"跳过"照样暂停，只是没有原因（中断照样计数）', (tester) async {
    await pumpRunning(tester);

    await tester.tap(find.byKey(const Key('focus-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pause-skip')));
    await tester.pumpAndSettle();

    expect(recorded, <InterruptionReason?>[null]);
    expect(store.open!.phase, FocusPhase.paused);
  });

  testWidgets('"取消"什么都不做：计时继续，也没有中断', (tester) async {
    await pumpRunning(tester);

    await tester.tap(find.byKey(const Key('focus-pause')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pause-cancel')));
    await tester.pumpAndSettle();

    expect(recorded, isEmpty);
    expect(store.open!.phase, FocusPhase.running);
  });

  testWidgets('五个原因都可选，标签与枚举一一对应', (tester) async {
    await pumpRunning(tester);

    await tester.tap(find.byKey(const Key('focus-pause')));
    await tester.pumpAndSettle();

    for (final reason in InterruptionReason.choices) {
      expect(
        find.byKey(Key('pause-reason-${reason.name}')),
        findsOneWidget,
        reason: '原因 ${reason.name} 没有出现在界面上',
      );
      expect(find.text(reason.label), findsOneWidget);
    }
  });
}
