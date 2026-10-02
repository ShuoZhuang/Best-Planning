import 'package:flutter/material.dart';
import 'package:personal_planner/platform/app_lock/app_lock_service.dart';

final class AppLockPage extends StatefulWidget {
  const AppLockPage({required this.service, super.key});

  final AppLockService service;

  @override
  State<AppLockPage> createState() => _AppLockPageState();
}

final class _AppLockPageState extends State<AppLockPage> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _enabled = false;
  bool _loading = true;
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await widget.service.isEnabled();
    if (mounted) {
      setState(() {
        _enabled = enabled;
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _enable() async {
    if (_password.text.isEmpty || _password.text != _confirmation.text) {
      setState(() => _status = '两次输入的密码必须一致且不能为空。');
      return;
    }
    await widget.service.enable(_password.text);
    _clearSecrets();
    setState(() {
      _enabled = true;
      _status = '应用锁已开启。';
    });
  }

  Future<void> _disable() async {
    final disabled = await widget.service.disable(_password.text);
    _clearSecrets();
    setState(() {
      _enabled = !disabled;
      _status = disabled ? '应用锁已关闭。' : '密码不正确，应用锁仍然开启。';
    });
  }

  void _clearSecrets() {
    _password.clear();
    _confirmation.clear();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return Scaffold(
      appBar: AppBar(title: const Text('应用锁')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text(
                _enabled ? '应用锁已开启' : '应用锁未开启',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '应用锁只阻止通过正常界面打开程序；本地 SQLite 数据库并未加密。'
                    '如果他人能够直接读取你的电脑文件，应用锁不能替代磁盘加密。',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _enabled ? '输入当前密码' : '设置密码',
                ),
              ),
              if (!_enabled) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _confirmation,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '再次输入密码'),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _enabled ? _disable : _enable,
                child: Text(_enabled ? '验证并关闭应用锁' : '开启应用锁'),
              ),
              if (_status != null) ...[
                const SizedBox(height: 16),
                Text(_status!),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
