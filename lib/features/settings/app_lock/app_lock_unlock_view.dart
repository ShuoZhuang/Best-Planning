import 'package:flutter/material.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

/// 启动时的解锁界面。
///
/// 应用锁此前只有设置页：`AppLockService.verify` 没有任何启动调用方，因此锁只能被"开启"，
/// 却永远不会真正拦住任何人——需求 §11.3 要求"首版应用锁只阻止通过正常 UI 打开程序"，
/// 而"阻止"发生在**启动路径**上，不在设置页里。这个界面就是那个缺失的调用方。
///
/// 它不自己判断是否上锁，也不决定解锁后显示什么：门控由 `PlannerApp` 做，这里只负责
/// "向用户要一次密码并把它交给 `verify`"。因此它可以在测试里单独挂载。
///
/// 失败次数与递增等待由 `AppLockService` 维护，这里不重复实现；界面只如实转述后果，
/// 免得用户以为卡住是程序出错。
final class AppLockUnlockView extends StatefulWidget {
  const AppLockUnlockView({
    required this.service,
    required this.onUnlocked,
    super.key,
  });

  final AppLockService service;
  final VoidCallback onUnlocked;

  @override
  State<AppLockUnlockView> createState() => _AppLockUnlockViewState();
}

final class _AppLockUnlockViewState extends State<AppLockUnlockView> {
  final _password = TextEditingController();
  bool _verifying = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
    });
    final unlocked = await widget.service.verify(_password.text);
    if (!mounted) return;
    // 无论成败都清掉输入：失败时留在框里既没有用，也容易被旁观者看到。
    _password.clear();
    setState(() {
      _verifying = false;
      _error = unlocked ? null : '密码不正确。连续失败会递增等待时间。';
    });
    if (unlocked) widget.onUnlocked();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '应用锁定',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text('输入密码以继续。应用锁只阻止通过正常界面打开程序，数据库文件并未加密。'),
            const SizedBox(height: 20),
            TextField(
              key: const Key('app-lock-password'),
              controller: _password,
              obscureText: true,
              autofocus: true,
              enabled: !_verifying,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '密码',
                border: OutlineInputBorder(),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              key: const Key('app-lock-unlock'),
              onPressed: _verifying ? null : _submit,
              child: Text(_verifying ? '验证中…' : '解锁'),
            ),
          ],
        ),
      ),
    ),
  );
}
