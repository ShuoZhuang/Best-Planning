// 启动调度（路线图 §3.6 / §11 Task 11）。
//
// 这一段代码的全部价值在于"**什么时候不发请求**"，而"没发生的事"最难验证。因此这里的核心断言
// 是**客户端被调用了几次**，不是"结果对不对"：
//   · 启动约 10 秒后检查一次；
//   · 之后 24 小时内一次都不再请求；
//   · 开关关掉时**一次请求都不发**（不是发了再丢掉结果）；
//   · `dispose()` 之后没有任何定时器还在跑——"程序关闭后不运行定时器，不创建 Windows 后台
//     服务"是 §3.6 的原话，而一个没人取消的 `Timer` 在测试里就是"挂着的定时器"报错，
//     在用户那里就是关掉窗口后还在联网。
//
// 用 `fakeAsync` 而不是真的等 10 秒：真实定时器会让用例变慢且不稳定，而这里要验证的恰恰是
// 时间轴本身。
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/update_check_scheduler.dart';
import 'package:personal_planner/application/update_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/domain/models/app_update.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';
import 'package:personal_planner/platform/update/github_release_client.dart';

final class _MutableClock implements Clock {
  DateTime now = DateTime.utc(2026, 10, 8, 1);
  @override
  DateTime nowUtc() => now;
}

/// 只数调用次数的客户端替身。
final class _CountingClient implements GithubReleaseClient {
  _CountingClient({this.failure});

  int calls = 0;
  Object? failure;

  @override
  Future<GithubReleasesResponse> fetchReleases({String? etag}) async {
    calls++;
    final error = failure;
    if (error != null) throw error;
    return const GithubReleasesResponse(releases: []);
  }
}

UpdateService _service({
  required _CountingClient client,
  required _MutableClock clock,
  required SettingsRepository settings,
}) => UpdateService(client: client, clock: clock, settings: settings);

void main() {
  test('启动约 10 秒后检查一次', () {
    fakeAsync((async) {
      final clock = _MutableClock();
      final client = _CountingClient();
      final scheduler = UpdateCheckScheduler(
        service: _service(
          client: client,
          clock: clock,
          settings: MemorySettingsRepository(),
        ),
        clock: clock,
      );

      scheduler.start();
      // 还没到点：一次都不该发。
      async.elapse(const Duration(seconds: 9));
      expect(client.calls, 0, reason: '启动 9 秒时还不该检查');

      async.elapse(const Duration(seconds: 2));
      expect(client.calls, 1, reason: '启动约 10 秒后应当检查一次');
      scheduler.dispose();
    });
  });

  test('启动后的检查走的是自动路径，不绕过 24 小时窗口', () {
    fakeAsync((async) {
      final settings = MemorySettingsRepository();
      final clock = _MutableClock();
      final client = _CountingClient();
      // 已经检查过（1 小时前）：启动后的那一次必须被窗口挡住，而不是再发一次请求。
      final seeded = JsonUpdateSettingsStore(settings: settings);
      final service = _service(
        client: client,
        clock: clock,
        settings: settings,
      );
      unawaited(seeded.save(UpdateSettings(lastCheckedUtc: clock.now)));

      final scheduler = UpdateCheckScheduler(service: service, clock: clock);
      scheduler.start();
      async.elapse(const Duration(minutes: 1));

      expect(client.calls, 0, reason: '窗口内不重复请求');
      scheduler.dispose();
    });
  });

  test('关闭自动检查后一次请求都不发', () {
    fakeAsync((async) {
      final settings = MemorySettingsRepository();
      final client = _CountingClient();
      final clock = _MutableClock();
      final service = _service(
        client: client,
        clock: clock,
        settings: settings,
      );
      final scheduler = UpdateCheckScheduler(service: service, clock: clock);

      var storeReady = false;
      unawaited(
        JsonUpdateSettingsStore(settings: settings)
            .save(const UpdateSettings(autoCheckEnabled: false))
            .then((_) => storeReady = true),
      );
      // 先把写入跑完（同一 fake zone 里的微任务）。
      async.flushMicrotasks();
      expect(storeReady, isTrue);

      scheduler.start();
      async.elapse(const Duration(minutes: 5));

      expect(client.calls, 0, reason: '§3.6：关闭自动检查后不得发起后台请求');
      scheduler.dispose();
    });
  });

  test('检查失败不影响启动，也不抛到外面', () {
    fakeAsync((async) {
      final clock = _MutableClock();
      final client = _CountingClient(
        failure: const UpdateCheckException(UpdateFailureReason.offline),
      );
      final scheduler = UpdateCheckScheduler(
        service: _service(
          client: client,
          clock: clock,
          settings: MemorySettingsRepository(),
        ),
        clock: clock,
      );

      scheduler.start();
      async.elapse(const Duration(minutes: 5));
      expect(client.calls, 1);
      scheduler.dispose();
    });
  });

  test('dispose() 之后不再有任何定时器：延迟启动的那一次也不会跑', () {
    fakeAsync((async) {
      final clock = _MutableClock();
      final client = _CountingClient();
      final scheduler = UpdateCheckScheduler(
        service: _service(
          client: client,
          clock: clock,
          settings: MemorySettingsRepository(),
        ),
        clock: clock,
      );

      scheduler.start();
      scheduler.dispose();
      // `fakeAsync` 在还有待处理定时器时 `flushTimers()` 不会报错，因此这里直接推进时间并
      // 断言"什么都没发生"——那才是"程序关闭后不运行定时器"的可验证形式。
      async.elapse(const Duration(minutes: 5));
      expect(client.calls, 0, reason: 'dispose 之后连首次检查都不该发生');
    });
  });

  test('重复 start() 只有一个定时器，不会检查两次', () {
    fakeAsync((async) {
      final clock = _MutableClock();
      final client = _CountingClient();
      final scheduler = UpdateCheckScheduler(
        service: _service(
          client: client,
          clock: clock,
          settings: MemorySettingsRepository(),
        ),
        clock: clock,
      );

      scheduler.start();
      scheduler.start();
      async.elapse(const Duration(minutes: 1));
      expect(client.calls, 1, reason: '重复 start 不该排第二个定时器');
      scheduler.dispose();
    });
  });

  test('dispose 期间的检查结果被丢弃，不会在关闭后再跑一遍', () {
    fakeAsync((async) {
      final clock = _MutableClock();
      final client = _CountingClient();
      final scheduler = UpdateCheckScheduler(
        service: _service(
          client: client,
          clock: clock,
          settings: MemorySettingsRepository(),
        ),
        clock: clock,
      );

      scheduler.start();
      // 请求已发出（计数为 1），此刻释放：完成回调不应再触发第二次检查。
      async.elapse(const Duration(seconds: 11));
      expect(client.calls, 1);
      scheduler.dispose();
      async.elapse(const Duration(days: 2));
      expect(client.calls, 1, reason: 'dispose 之后不该再排下一次');
    });
  });

  test('启动延迟做成常量，且是约 10 秒', () {
    expect(UpdateCheckScheduler.startupDelay, const Duration(seconds: 10));
  });
}
