// 点击/冷启动的诊断装饰器。**它存在的理由是一次猜错的代价**：本会话里我曾把"没重建注册表键"
// 当成"`initialize()` 没跑到"，而真相是 MSIX 把写入虚拟化了（见
// `docs/testing/flow-verification.md` 第十节）。点击这条链路若没有落盘痕迹，"点了没反应"
// 就只能靠猜——这几条用例守的是"痕迹必须真实且不越权判断"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/domain/repositories/notification_port.dart';
import 'package:personal_planner/platform/diagnostics/file_diagnostic_log.dart';
import 'package:personal_planner/platform/notifications/diagnostic_notification_port.dart';

/// 最小假端口：记录被调用的成员，并可指定冷启动 payload。
final class _FakePort implements NotificationPort {
  _FakePort({this.launch, this.failPending = false});
  final NotificationPayload? launch;

  /// 模拟"原生调用抛异常"，用来验面包屑的失败分支。
  final bool failPending;
  final List<String> calls = [];
  void Function(NotificationPayload payload)? tapped;

  @override
  Future<NotificationCapability> capability() async {
    calls.add('capability');
    return const NotificationCapability(
      canSchedule: true,
      canCancelReliably: true,
    );
  }

  @override
  Future<List<PendingNotification>> pendingNotifications() async {
    calls.add('pendingNotifications');
    if (failPending) throw StateError('原生调用炸了');
    return const [];
  }

  @override
  Future<void> scheduleOneShot(NotificationRequest request) async {
    calls.add('scheduleOneShot:${request.id}');
  }

  @override
  Future<void> cancel(String id) async => calls.add('cancel:$id');

  @override
  void onTapped(void Function(NotificationPayload payload) handler) {
    calls.add('onTapped');
    tapped = handler;
  }

  @override
  Future<NotificationPayload?> launchPayload() async {
    calls.add('launchPayload');
    return launch;
  }
}

NotificationPayload payloadWith(String route) => NotificationPayload(
  notificationId: 'planner.deadline.x',
  kind: NotificationKind.deadline,
  entityId: 'task-1',
  route: route,
);

void main() {
  late Directory temp;
  late FileDiagnosticLog log;
  late String logPath;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('diag-port-test');
    logPath = '${temp.path}${Platform.pathSeparator}d.log';
    log = FileDiagnosticLog(logPath);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('点击到达时记下 route，并且照旧把 payload 交给上层', () async {
    final inner = _FakePort();
    final port = DiagnosticNotificationPort(inner: inner, log: log);
    NotificationPayload? received;
    port.onTapped((payload) => received = payload);

    inner.tapped!(payloadWith('/tasks/task-1'));
    // 诊断写入是同步的，但给事件循环一拍以稳妥。
    await Future<void>.delayed(Duration.zero);

    expect(received?.route, '/tasks/task-1', reason: '装饰器不得吞掉这次点击');
    final content = File(logPath).readAsStringSync();
    expect(content, contains('通知被点击（应用在运行）'));
    expect(content, contains('route=/tasks/task-1'));
  });

  test('冷启动拿到 payload 时记下拉起的 route', () async {
    final inner = _FakePort(launch: payloadWith('/tasks/task-9'));
    final port = DiagnosticNotificationPort(inner: inner, log: log);

    final result = await port.launchPayload();

    expect(result?.route, '/tasks/task-9');
    final content = File(logPath).readAsStringSync();
    expect(content, contains('冷启动由通知拉起'));
    expect(content, contains('route=/tasks/task-9'));
  });

  test('冷启动没拿到 payload 时如实记"未拿到"，而不是记成失败或成功', () async {
    final inner = _FakePort();
    final port = DiagnosticNotificationPort(inner: inner, log: log);

    final result = await port.launchPayload();

    expect(result, isNull);
    final content = File(logPath).readAsStringSync();
    expect(content, contains('冷启动未拿到通知 payload'));
    // **关键**：这一层看不到"到底是不是被通知拉起的"，因此不许写"失败"或"成功"。
    expect(content, isNot(contains('失败')));
    expect(content, isNot(contains('成功')));
  });

  test('其余成员原样转发（装饰器不得悄悄改变行为）', () async {
    final inner = _FakePort();
    final port = DiagnosticNotificationPort(inner: inner, log: log);

    await port.capability();
    await port.pendingNotifications();
    await port.scheduleOneShot(
      NotificationRequest(
        id: 'x',
        scheduledAtUtc: DateTime.utc(2026, 10, 4, 9),
        title: 't',
        body: 'b',
        payload: 'p',
      ),
    );
    await port.cancel('x');

    expect(inner.calls, [
      'capability',
      'pendingNotifications',
      'scheduleOneShot:x',
      'cancel:x',
    ]);
  });
  // 崩溃定位用的面包屑（2026-10-04）：`0xc0000409` 至今没有栈可用，因此"最后一条落盘的
  // 面包屑"就是栈的替代品。这两条用例守住它**真的在原生调用前后各落一行**，以及
  // **失败时先记再抛**（吞掉异常会掩盖真正的故障）。
  test('原生调用前后各落一行面包屑，标签一致', () async {
    final inner = _FakePort();
    final port = DiagnosticNotificationPort(inner: inner, log: log);

    await port.pendingNotifications();

    final written = File(logPath).readAsLinesSync();
    expect(
      written.where((line) => line.contains('原生调用进入：查询待发通知')).length,
      1,
      reason: '进入必须恰好记一次',
    );
    expect(
      written.where((line) => line.contains('原生调用返回：查询待发通知')).length,
      1,
      reason: '返回必须恰好记一次——崩溃时缺的就是这一行',
    );
    expect(inner.calls, ['pendingNotifications'], reason: '照旧转发');
  });

  test('原生调用抛异常时先记"失败"再把异常抛出去', () async {
    final inner = _FakePort(failPending: true);
    final port = DiagnosticNotificationPort(inner: inner, log: log);

    await expectLater(port.pendingNotifications(), throwsStateError);

    final written = File(logPath).readAsLinesSync();
    expect(
      written.where((line) => line.contains('原生调用进入：查询待发通知')).length,
      1,
    );
    expect(
      written.where((line) => line.contains('原生调用失败：查询待发通知')).length,
      1,
      reason: '失败要留下痕迹，否则排查时只看到"进入"会误判成崩溃',
    );
    expect(
      written.where((line) => line.contains('原生调用返回：查询待发通知')).length,
      0,
      reason: '没返回就不该记返回',
    );
  });
}