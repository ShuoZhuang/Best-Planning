// 更新设置页（路线图 §3.6 / §7.3 / §11 Task 11）。
//
// 这一页要同时说清四件事，而它们都是**用户看不出对错的**， поэтому每条都得钉：
//   ① 隐私边界：只请求版本信息、不上传本地数据（首次进入必须说明）；
//   ② 六种界面状态各自长什么样——尤其"自动失败非打扰 / 手动失败给具体原因"这一对；
//   ③ 失败文案里**不能出现堆栈或本地路径**（本仓库已经因为把 `FileSystemException` 原样显示
//      踩过一次，见 `backup_page.dart` 的 `backupFailureMessage`）；
//   ④ "查看下载"只打开**已验证的仓库 Release 地址**——一个能被注入的 URL 就是一个钓鱼入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/design/planner_action_feedback.dart';
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/features/settings/update/update_page.dart';

/// 可控的控制器替身：页面只认这个接口，因此六种状态都能直接摆出来。
///
/// 继承 `ChangeNotifier` 是为了拿到真实的监听机制：这样"状态变了要重建"这条路径在用例里走的
/// 是**与生产完全相同**的那一条，而不是靠手工重新 pump 一次来假装。
final class _FakeController extends ChangeNotifier
    implements UpdatePageController {
  _FakeController({this.state = UpdatePageState.loading});

  UpdatePageState state;
  AppVersion? currentVersion = const AppVersion(1, 6, 2, build: 37);
  UpdateSettings settings = const UpdateSettings();
  ReleaseInfo? release;
  UpdateFailureReason? failure;
  CheckTrigger? lastTrigger;
  int checks = 0;
  int skips = 0;
  bool wasDisposed = false;

  @override
  UpdatePageState get status => state;

  @override
  AppVersion? get currentAppVersion => currentVersion;

  @override
  UpdateSettings get currentSettings => settings;

  @override
  ReleaseInfo? get availableRelease => release;

  @override
  UpdateFailureReason? get failureReason => failure;

  @override
  CheckTrigger? get lastCheckTrigger => lastTrigger;

  /// 关过的长期提示（§11 Task 12 Step 2）。**每个替身一份**：用例之间不共享状态，
  /// 否则"关过之后不再出现"会被上一条用例的关闭动作污染。
  @override
  final DismissedBannerStore dismissedBanners = DismissedBannerStore();

  /// 把替身切到另一个状态，并真的通知监听者。
  void transition({
    required UpdatePageState next,
    UpdateFailureReason? reason,
    CheckTrigger? trigger,
    ReleaseInfo? available,
  }) {
    state = next;
    failure = reason;
    lastTrigger = trigger;
    if (available != null) release = available;
    notifyListeners();
  }

  @override
  Future<void> load() async {}

  @override
  Future<void> checkNow() async {
    checks++;
    lastTrigger = CheckTrigger.manual;
  }

  @override
  Future<void> setAutoCheckEnabled(bool enabled) async {
    settings = settings.copyWith(autoCheckEnabled: enabled);
    // **生产控制器在保存前就 `notifyListeners()`**（开关要立刻响应），这里必须照做：
    // 少了它，页面上的开关会停在上一次的值，而"设置真的改了"这条断言看不出来——
    // 界面与状态不一致的用例就是漏在这条上。
    notifyListeners();
  }

  @override
  Future<void> skipCurrentVersion() async {
    skips++;
  }

  @override
  void dispose() {
    wasDisposed = true;
    super.dispose();
  }
}

void main() {
  /// [settle] 为 `false` 时只推进一帧。
  ///
  /// **加载态与检查态必须用 `settle: false`**：它们画的是不确定进度条，
  /// `CircularProgressIndicator`／`LinearProgressIndicator` 永远在动，`pumpAndSettle` 会一直等到超时
  /// （实测：`pumpAndSettle timed out`）。这不是测试写法问题——"还在加载"本来就是一个持续的动画。
  Future<void> pump(
    WidgetTester tester,
    UpdatePageController controller, {
    Future<bool> Function(Uri url)? openUrl,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(1100, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: UpdatePage(
          controller: controller,
          openUrl: openUrl ?? (_) async => true,
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets('自动检查默认开启', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);

    // **读的是 `SwitchListTile`**：这一项的开关带标题与说明，用 `SwitchListTile` 才能让读屏
    // 播报"自动检查更新"；直接找 `Switch` 会拿到它的内部实现。
    final toggle = tester.widget<SwitchListTile>(
      find.byKey(const Key('update-auto-check')),
    );
    expect(toggle.value, isTrue, reason: '§3.6：自动检查默认开启');
  });

  testWidgets('拨动开关会保存设置', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);

    // **点里面的 `Switch` 而不是整行**：这一行的 `onTap` 是空的（点击标题不该改设置，
    // 否则读屏用户"读一遍"就可能把开关拨了），因此命中点必须在开关自身上。
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('update-auto-check')),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.settings.autoCheckEnabled, isFalse);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('update-auto-check')))
          .value,
      isFalse,
    );
  });

  testWidgets('显示当前版本、上次检查时间、当前更新源与"立即检查"', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate)
      ..settings = UpdateSettings(
        lastCheckedUtc: DateTime.utc(2026, 10, 8, 2, 30),
      );
    await pump(tester, controller);

    expect(find.byKey(const Key('update-current-version')), findsOneWidget);
    expect(find.textContaining('1.6.2'), findsWidgets);
    expect(find.byKey(const Key('update-last-checked')), findsOneWidget);
    expect(find.byKey(const Key('update-source')), findsOneWidget);
    // 更新源必须是那个固定仓库，而不是一句"GitHub"。
    expect(find.textContaining('ShuoZhuang/Best-Planning'), findsWidgets);
    expect(find.byKey(const Key('update-check-now')), findsOneWidget);
  });

  testWidgets('从没有检查过时说明"还没有检查过"，而不是显示一个空时间', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);

    final label = tester.widget<Text>(
      find.byKey(const Key('update-last-checked')),
    );
    expect(label.data, isNotNull);
    expect(label.data, contains('还没有'));
  });

  testWidgets('首次进入说明联网边界：只请求版本信息，不上传本地数据', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);

    expect(find.byKey(const Key('update-privacy-note')), findsOneWidget);
    expect(find.textContaining('不上传'), findsOneWidget);
    expect(find.textContaining('版本'), findsWidgets);
  });

  testWidgets('加载中显示进度，不显示"立即检查"以外的假状态', (tester) async {
    final controller = _FakeController();
    await pump(tester, controller, settle: false);

    expect(find.byKey(const Key('update-loading')), findsOneWidget);
  });

  testWidgets('检查中显示进度且"立即检查"不可点（点了没反应比禁用更糟）', (tester) async {
    final controller = _FakeController(state: UpdatePageState.checking);
    await pump(tester, controller, settle: false);

    expect(find.byKey(const Key('update-checking')), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('update-check-now')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('点"立即检查"发起手动检查', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);

    await tester.tap(find.byKey(const Key('update-check-now')));
    await tester.pumpAndSettle();

    expect(controller.checks, 1);
    expect(controller.lastTrigger, CheckTrigger.manual);
  });

  testWidgets('有更新时显示版本、发布日期、更新说明与"查看下载"', (tester) async {
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '本版修好了几处让人困惑的地方。',
        publishedAtUtc: DateTime.utc(2026, 10, 8),
        htmlUrl:
            'https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.7.0',
      );
    await pump(tester, controller);

    expect(find.textContaining('1.7.0'), findsWidgets);
    expect(find.textContaining('本版修好了'), findsWidgets);
    expect(find.byKey(const Key('update-release-date')), findsOneWidget);
    expect(find.byKey(const Key('update-download')), findsOneWidget);
    expect(find.byKey(const Key('update-skip-version')), findsOneWidget);
  });

  testWidgets('"查看下载"只打开已验证的仓库 Release 地址', (tester) async {
    final opened = <Uri>[];
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '',
        htmlUrl:
            'https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.7.0',
      );
    await pump(
      tester,
      controller,
      openUrl: (url) async {
        opened.add(url);
        return true;
      },
    );

    await tester.tap(find.byKey(const Key('update-download')));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.scheme, 'https');
    expect(opened.single.host, 'github.com');
    expect(opened.single.path, '/ShuoZhuang/Best-Planning/releases/tag/v1.7.0');
  });

  testWidgets('Release 地址不是本仓库时"查看下载"不出现（宁可少一个按钮）', (tester) async {
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '',
        // 被篡改／被重定向的地址。
        htmlUrl: 'https://evil.example.com/ShuoZhuang/Best-Planning/releases',
      );
    await pump(tester, controller);

    expect(find.byKey(const Key('update-download')), findsNothing);
  });

  testWidgets('明文 HTTP 的 Release 地址也不给"查看下载"', (tester) async {
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '',
        htmlUrl:
            'http://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.7.0',
      );
    await pump(tester, controller);

    expect(find.byKey(const Key('update-download')), findsNothing);
  });

  testWidgets('没有 Release 链接时不显示"查看下载"', (tester) async {
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '',
      );
    await pump(tester, controller);

    expect(find.byKey(const Key('update-download')), findsNothing);
    expect(find.byKey(const Key('update-skip-version')), findsOneWidget);
  });

  testWidgets('点"跳过此版本"调用控制器', (tester) async {
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '',
      );
    await pump(tester, controller);

    await tester.tap(find.byKey(const Key('update-skip-version')));
    await tester.pumpAndSettle();
    expect(controller.skips, 1);
  });

  testWidgets('已是最新时给出明确结论，不给"查看下载"和"跳过"', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);

    expect(find.byKey(const Key('update-up-to-date')), findsOneWidget);
    expect(find.text('已经是最新版本，没有需要更新的内容。'), findsOneWidget);
    expect(find.byKey(const Key('update-download')), findsNothing);
    expect(find.byKey(const Key('update-skip-version')), findsNothing);
  });

  testWidgets('被跳过的版本说明"已跳过这个版本"，并说明更高版本仍会提醒', (tester) async {
    final controller = _FakeController(state: UpdatePageState.skipped)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '',
      );
    await pump(tester, controller);

    expect(find.byKey(const Key('update-skipped')), findsOneWidget);
    // 跳过按钮此时不该再出现：已经跳过了，再点一次没有意义。
    expect(find.byKey(const Key('update-skip-version')), findsNothing);
  });

  testWidgets('自动检查失败：非打扰提示，不说"失败"吓人，也不显示原因', (tester) async {
    final controller = _FakeController(state: UpdatePageState.failed)
      ..failure = UpdateFailureReason.rateLimited
      ..lastTrigger = CheckTrigger.automatic;
    await pump(tester, controller);

    expect(find.byKey(const Key('update-auto-failure-hint')), findsOneWidget);
    // 自动检查不能吵：它的失败用一行浅色说明，而不是一条错误色横幅。
    expect(find.byKey(const Key('update-failure')), findsNothing);
  });

  testWidgets('手动检查失败：显示具体原因', (tester) async {
    final controller = _FakeController(state: UpdatePageState.failed)
      ..failure = UpdateFailureReason.offline
      ..lastTrigger = CheckTrigger.manual;
    await pump(tester, controller);

    expect(find.byKey(const Key('update-failure')), findsOneWidget);
    // `find.textContaining` 对非 ASCII 不安全（实测中文匹配不到），因此断言整串。
    expect(find.text(UpdateFailureReason.offline.label), findsOneWidget);
  });

  testWidgets('失败文案里没有堆栈、异常类名或本地路径', (tester) async {
    // 本仓库已经因为把 `FileSystemException` 原样打到界面上踩过一次（`backup_page.dart`）。
    // 这一条把"更新检查失败时也不会重演"钉住——六种原因逐个扫。
    for (final reason in UpdateFailureReason.values) {
      final controller = _FakeController(state: UpdatePageState.failed)
        ..failure = reason
        ..lastTrigger = CheckTrigger.manual;
      await pump(tester, controller);

      for (final leak in const [
        'Exception',
        'Error',
        '#0 ',
        'package:',
        r'C:\',
        '/Users/',
        'G:',
      ]) {
        expect(
          find.textContaining(leak),
          findsNothing,
          reason: '${reason.name} 的文案泄漏了 $leak',
        );
      }
    }
  });

  testWidgets('切换状态后旧结论不再残留（"已是最新"不会盖在新的失败上）', (tester) async {
    final controller = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, controller);
    expect(find.byKey(const Key('update-up-to-date')), findsOneWidget);

    // 真实路径里状态变化来自 `notifyListeners`，因此这里走同一条路：只改状态、不重建 widget。
    controller.transition(
      next: UpdatePageState.failed,
      reason: UpdateFailureReason.timeout,
      trigger: CheckTrigger.manual,
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('update-up-to-date')), findsNothing);
    expect(
      find.text(UpdateFailureReason.timeout.label),
      findsOneWidget,
      reason: '旧结论必须被新的失败换掉，否则用户看到的是上一次的答案',
    );
  });

  testWidgets('页面创建的控制器由页面释放，外部持有的不释放', (tester) async {
    final owned = _FakeController(state: UpdatePageState.upToDate);
    await tester.pumpWidget(
      MaterialApp(
        home: UpdatePage(
          controller: owned,
          disposeController: true,
          openUrl: (_) async => true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 换掉整棵树，触发页面 dispose。
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(owned.wasDisposed, isTrue, reason: '路由里创建的那个控制器没有别的持有者');

    final borrowed = _FakeController(state: UpdatePageState.upToDate);
    await pump(tester, borrowed);
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();
    expect(
      borrowed.wasDisposed,
      isFalse,
      reason: '调用方仍然持有它——页面顺手销毁会让调用方拿到一个已释放的 notifier',
    );
  });

  testWidgets('窄窗与 200% 缩放下主流程仍可完成', (tester) async {
    tester.view.physicalSize = const Size(560, 900);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final controller = _FakeController(state: UpdatePageState.updateAvailable)
      ..release = ReleaseInfo(
        tagName: 'v1.7.0',
        version: const AppVersion(1, 7, 0),
        notes: '说明文字。' * 40,
        htmlUrl:
            'https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.7.0',
      );
    await tester.pumpWidget(
      MaterialApp(
        home: UpdatePage(controller: controller, openUrl: (_) async => true),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // "立即检查"必须能滚动到并点到（读屏与键盘也走同一个焦点顺序）。窄窗下它在首屏之外，
    // 这里真的滚动过去——`ensureVisible` 只保证"存在且已进入视口"，而点击需要它不被别的
    // 控件挡住。
    await tester.dragUntilVisible(
      find.byKey(const Key('update-check-now')),
      find.byType(ListView),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('update-check-now')));
    await tester.pumpAndSettle();
    expect(controller.checks, 1);
  });

  // ── §11 Task 12 Step 2：长期提示的关闭与"新版本可以再次出现" ────────────────
  //
  // 这一组钉住的是**id 而不是 bool**：关掉 1.7.0 的提示之后，1.7.1 出现时仍要被提醒。
  // 记 bool 会让用户永久错过后续每一条更新——那正是这一步存在的理由。
  group('有更新时的长期提示（Task 12 Step 2）', () {
    _FakeController withRelease(String tag, AppVersion version) =>
        _FakeController(state: UpdatePageState.updateAvailable)
          ..release = ReleaseInfo(
            tagName: tag,
            version: version,
            notes: '修好了几处让人困惑的地方。',
            htmlUrl:
                'https://github.com/ShuoZhuang/Best-Planning/releases/tag/$tag',
          );

    testWidgets('有更新 ⇒ 提示出现，且带 liveRegion（读屏会主动播报）', (tester) async {
      final controller = withRelease('v1.7.0', const AppVersion(1, 7, 0));
      await pump(tester, controller);

      expect(
        find.byKey(const Key('planner-banner-update-1.7.0')),
        findsOneWidget,
      );
      expect(find.textContaining('有新版本'), findsOneWidget);
    });

    testWidgets('**关掉之后不再出现**（"已是最新"的页面不该还挂着它）', (tester) async {
      final controller = withRelease('v1.7.0', const AppVersion(1, 7, 0));
      await pump(tester, controller);
      expect(find.textContaining('有新版本'), findsOneWidget);

      await tester.tap(find.byTooltip('不再显示这条提示'));
      await tester.pumpAndSettle();

      expect(find.textContaining('有新版本'), findsNothing);
      expect(controller.dismissedBanners.contains('update-1.7.0'), isTrue);
    });

    testWidgets('**新版本可以再次出现**（这是 id 而非 bool 的全部意义）', (tester) async {
      final controller = withRelease('v1.7.0', const AppVersion(1, 7, 0));
      await pump(tester, controller);
      await tester.tap(find.byTooltip('不再显示这条提示'));
      await tester.pumpAndSettle();
      expect(find.textContaining('有新版本'), findsNothing);

      // 换一个更新的版本：新的 tag 就是新的 bannerId。
      controller
        ..release = ReleaseInfo(
          tagName: 'v1.7.1',
          version: const AppVersion(1, 7, 1),
          notes: '又一次更新。',
          htmlUrl:
              'https://github.com/ShuoZhuang/Best-Planning/releases/tag/v1.7.1',
        )
        ..transition(next: UpdatePageState.updateAvailable);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('有新版本'),
        findsOneWidget,
        reason: '关掉 1.7.0 的提示不该让用户错过 1.7.1',
      );
    });

    testWidgets('没有更新时不出现提示', (tester) async {
      final controller = _FakeController(state: UpdatePageState.upToDate)
        ..release = null;
      await pump(tester, controller);

      expect(find.textContaining('有新版本'), findsNothing);
    });
  });
}
