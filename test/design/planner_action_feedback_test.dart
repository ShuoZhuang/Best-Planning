// 统一的动作反馈（路线图 §11 Task 12）。
//
// 三条要求各自钉在这里：
//   ① 完成、跳过本次、修改本周目标和暂停周期都有撤销入口；
//   ② 同一长期提示关闭后不重复出现；新 proposal 或新版本可以再次出现；
//   ③ 长期横幅不遮挡底部内容，键盘可聚焦关闭按钮，读屏能播报状态变化。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/design/planner_action_feedback.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  // 默认的 800×600 测试视口放不下带动作的 `SnackBar`——它的「撤销」按钮会被排到视口之外
  // （实测命中测试的坐标是 749.9, 638，超出了 800×600），于是 `tap` 打不中。
  // 真机上窗口远大于这个尺寸，因此这里给一个接近真实的窗口，而不是把断言放宽。
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

void main() {
  group('Task 12 可撤销动作', () {
    /// 弹一条可撤销提示，并等它**真的落位**。
    ///
    /// **为什么必须等**：只 `pump()` 一帧时气泡还在屏幕下方之外（实测命中坐标 y=938，
    /// 而视口高 900）——那时 `tap` 打不中，测试会给出"回调没被调用"这种**误导性**的失败。
    /// `pumpAndSettle` 把入场动画走完，控件才在可点位置上。
    Future<void> showAndSettle(
      WidgetTester tester,
      String message, {
      required VoidCallback onUndo,
      String undoLabel = '撤销',
    }) async {
      late BuildContext captured;
      await _pump(
        tester,
        Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      );
      showUndoableAction(
        captured,
        message: message,
        undoLabel: undoLabel,
        onUndo: onUndo,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('撤销入口出现在气泡上，点一次只回调一次', (tester) async {
      var undoCount = 0;
      await showAndSettle(tester, '已完成「算法作业」', onUndo: () => undoCount++);

      expect(find.text('已完成「算法作业」'), findsOneWidget);
      expect(find.text('撤销'), findsOneWidget);

      await tester.tap(find.text('撤销'));
      await tester.pumpAndSettle();
      expect(undoCount, 1, reason: '① 撤销入口必须真的通到回调');
    });

    testWidgets('撤销标签可改（不同动作的文案不一样）', (tester) async {
      await showAndSettle(tester, '已跳过本次', undoLabel: '恢复这一块', onUndo: () {});

      expect(find.text('恢复这一块'), findsOneWidget);
      expect(find.text('撤销'), findsNothing);
    });

    testWidgets('带动作的气泡**自己会消失**（不会永久挂在屏幕上）', (tester) async {
      await showAndSettle(tester, '已完成', onUndo: () {});
      expect(find.text('已完成'), findsOneWidget);

      // 气泡带动作时的时长是 8 秒（`plannerActionableMessageDuration`）。
      // 这条断言盯住的是"它真的会走"——`SnackBar` 默认在有动作时 `persist` 为真，
      // 那会让提示永远留在屏幕上，而 `plannerSnackBar` 正是为此显式传了 `persist: false`。
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(find.text('已完成'), findsNothing);
    });
  });

  group('Task 12 长期提示', () {
    testWidgets('渲染标题、说明、主动作与关闭按钮', (tester) async {
      var acted = 0;
      var dismissed = 0;
      await _pump(
        tester,
        PlannerPersistentBanner(
          bannerId: 'proposal-1',
          title: '有一份新的安排建议',
          message: '确认后才会生效',
          primaryActionLabel: '去看看',
          primaryAction: () => acted++,
          onDismiss: () => dismissed++,
        ),
      );

      expect(find.text('有一份新的安排建议'), findsOneWidget);
      expect(find.text('确认后才会生效'), findsOneWidget);

      await tester.tap(
        find.byKey(const Key('planner-banner-action-proposal-1')),
      );
      await tester.pump();
      expect(acted, 1);

      await tester.tap(
        find.byKey(const Key('planner-banner-dismiss-proposal-1')),
      );
      await tester.pump();
      expect(dismissed, 1, reason: '③ 关闭按钮必须可点');
    });

    testWidgets('没有关闭回调时**不画**关闭按钮（不显示点了没反应的按钮）', (tester) async {
      await _pump(
        tester,
        const PlannerPersistentBanner(
          bannerId: 'no-dismiss',
          title: '这条提示不该被关掉',
        ),
      );

      expect(
        find.byKey(const Key('planner-banner-dismiss-no-dismiss')),
        findsNothing,
      );
    });

    testWidgets('关闭按钮有语义标签，键盘可聚焦并能触发（③）', (tester) async {
      var dismissed = 0;
      await _pump(
        tester,
        PlannerPersistentBanner(
          bannerId: 'kbd',
          title: '提示',
          onDismiss: () => dismissed++,
          dismissTooltip: '不再显示这条提示',
        ),
      );

      // tooltip 同时就是语义标签：读屏念的是"不再显示这条提示"，
      // 而不是一个没有名字的图标按钮。
      expect(
        tester
            .getSemantics(find.byKey(const Key('planner-banner-dismiss-kbd')))
            .tooltip,
        '不再显示这条提示',
      );

      // **键盘可达**：先聚焦，再回车触发。若控件不在焦点遍历里，这条会红。
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(dismissed, 1, reason: '③ 键盘必须能关闭它');
    });

    testWidgets('整条提示是 liveRegion（读屏会播报状态变化）（③）', (tester) async {
      await _pump(
        tester,
        const PlannerPersistentBanner(
          bannerId: 'live',
          title: '统计加载失败',
          message: '可以重试',
        ),
      );

      // **直接查那个带 key 的节点本身**：key 现在就在 `Semantics` 上（`liveRegion` 与它在
      // 同一个节点），因此 `tester.widget<Semantics>(byKey(...))` 拿到的正是标了
      // `liveRegion` 的那一个。用 `find.descendant` 会恒不命中——`descendant` 不包含根节点，
      // 而 `Semantics` 就是根节点本身（第一版两次都这么写错过）。
      final banner = tester.widget<Semantics>(
        find.byKey(const Key('planner-banner-live')),
      );
      expect(
        banner.properties.liveRegion,
        isTrue,
        reason: '③ 读屏必须能在它出现时播报，而不是等用户自己撞上去',
      );
      // `container` 是 `Semantics` 控件的字段（不属于 `SemanticsProperties`），
      // 它让这一整条成为一个独立的语义节点——读屏因此会把标题、说明与按钮一起念出来。
      expect(banner.container, isTrue);
    });

    testWidgets('它是文档流里的一块，不覆盖底部内容（③）', (tester) async {
      // 用一个"提示 + 底部一行"的短页面：提示若用 Overlay/Stack 浮起来，
      // 底部那行的命中测试会被它挡住。这里断言两者都完整可见且可点。
      var tappedBottom = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                const PlannerPersistentBanner(
                  bannerId: 'flow',
                  title: '一条长期提示',
                  message: '说明',
                ),
                Expanded(
                  child: Center(
                    child: TextButton(
                      key: const Key('bottom-content'),
                      onPressed: () => tappedBottom++,
                      child: const Text('底部内容'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('bottom-content')));
      await tester.pump();
      expect(tappedBottom, 1, reason: '③ 长期横幅不该挡住底部内容的点击');
    });
  });

  group('Task 12 关闭记忆', () {
    test('同一 id 关过之后记为已关，重复关返回 false（②）', () {
      final store = DismissedBannerStore();

      expect(store.contains('proposal-1'), isFalse);
      expect(store.dismiss('proposal-1'), isTrue, reason: '第一次关是新的关闭');
      expect(store.contains('proposal-1'), isTrue);
      expect(
        store.dismiss('proposal-1'),
        isFalse,
        reason: '重复关同一条不该被当成"又有变化"，否则界面会无意义地重建',
      );
    });

    test('新 id 不受旧关闭影响——新 proposal 仍然要提醒（②）', () {
      final store = DismissedBannerStore(['proposal-1']);

      expect(store.contains('proposal-1'), isTrue);
      expect(
        store.contains('proposal-2'),
        isFalse,
        reason: '② 用 id 而不是 bool 的全部意义：新内容必须能再次出现',
      );
    });

    test('可以从一组已知的已关闭 id 构造（跨会话恢复的形状）', () {
      final store = DismissedBannerStore(['a', 'b']);

      expect(store.ids, {'a', 'b'});
      expect(store.contains('a'), isTrue);
      expect(store.contains('c'), isFalse);
    });
  });
}
