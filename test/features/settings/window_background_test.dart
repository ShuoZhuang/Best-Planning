// 「窗口与后台」：关闭主窗口是收进托盘后台运行，还是直接退出。
//
// 这里是**行为**而不是外观，因此用假端口测三层接缝：设置存储 → 应用服务 → 页面。
// 原生托盘本身（Shell_NotifyIcon、右键菜单）只能人工确认，见文件末尾的说明。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/application/window_behavior_service.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/features/settings/window/window_background_page.dart';
import 'package:personal_planner/platform/windows/window_shell.dart';

/// 只记下"被要求做什么"，并回答托盘是否可用（以及原因）。
final class _RecordingShell implements WindowShell {
  _RecordingShell({this.trayAvailable = true, this.detail = 'ok'});

  final bool trayAvailable;
  final String detail;
  final List<WindowCloseBehavior> calls = [];

  @override
  Future<TrayStatus> setCloseBehavior(WindowCloseBehavior behavior) async {
    calls.add(behavior);
    return TrayStatus(available: trayAvailable, detail: detail);
  }
}

/// 领域里已有 `MemorySettingsRepository`，这里另写一个是为了**number of writes** 也要可见：
/// "启动时下发"必须只读不写，而只读的契约只能靠观察写入次数来钉住。
final class _SpySettings implements SettingsRepository {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
}

void main() {
  late _SpySettings repository;
  late SettingsService settings;

  setUp(() {
    repository = _SpySettings();
    settings = SettingsService(repository: repository);
  });

  test('应用选择会先存下再下发给宿主窗口', () async {
    final shell = _RecordingShell();
    final service = WindowBehaviorService(settings: settings, shell: shell);

    final status = await service.apply(WindowCloseBehavior.quit);
    expect(status.available, isTrue);
    expect(status.detail, 'ok');
    expect(shell.calls, [WindowCloseBehavior.quit]);
    expect(repository.values['window.closeBehavior.v1'], 'quit');
    // 存下的值必须能被读回：否则下次启动的 pushStored 会下发旧行为。
    expect(await service.load(), WindowCloseBehavior.quit);
  });

  test('启动时下发已存的行为，且不写回存储', () async {
    await settings.saveCloseBehavior(WindowCloseBehavior.quit);
    final writesBefore = repository.writes;

    final shell = _RecordingShell();
    await WindowBehaviorService(settings: settings, shell: shell).pushStored();

    expect(shell.calls, [WindowCloseBehavior.quit]);
    expect(repository.writes, writesBefore, reason: 'pushStored 只读不写');
  });

  testWidgets('页面显示两种行为，改动会存下并下发', (tester) async {
    final shell = _RecordingShell();
    await tester.pumpWidget(
      MaterialApp(
        home: WindowBackgroundPage(
          windowBehavior: WindowBehaviorService(
            settings: settings,
            shell: shell,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('最小化到后台运行'), findsOneWidget);
    expect(find.text('直接退出程序'), findsOneWidget);

    await tester.tap(find.text('直接退出程序'));
    await tester.pumpAndSettle();

    // 第一次是打开页面时的同步（并借此得知托盘可用性），第二次才是用户的选择。
    expect(shell.calls, [
      WindowCloseBehavior.minimizeToTray,
      WindowCloseBehavior.quit,
    ]);
    expect(await settings.loadCloseBehavior(), WindowCloseBehavior.quit);
  });

  testWidgets('托盘不可用时如实告知原因，而不是假装设置成功', (tester) async {
    // 托盘建不出来时"收进后台"不会生效——窗口藏了就再也找不回来。这里钉住两件事：
    // 界面必须说明，而且要说清**原因**（用户与支持者都无从猜出 shell_add_failed:5 这种事实）。
    final shell = _RecordingShell(
      trayAvailable: false,
      detail: 'shell_add_failed:5',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: WindowBackgroundPage(
          windowBehavior: WindowBehaviorService(
            settings: settings,
            shell: shell,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 打开页面就该看到提示：不必等用户改一次设置才告诉他托盘不可用。
    expect(find.textContaining('托盘图标未创建成功'), findsOneWidget);

    // 点**另一个**选项：分段按钮在"选择没变"时不会回调，点当前项不会触发任何操作。
    await tester.tap(find.text('直接退出程序'));
    await tester.pumpAndSettle();

    expect(find.textContaining('shell_add_failed:5'), findsOneWidget);
  });
}
