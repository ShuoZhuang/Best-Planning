import 'package:flutter/material.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';

final class BackupPage extends StatefulWidget {
  const BackupPage({
    required this.backups,
    required this.files,
    this.erasure,
    super.key,
  });

  final BackupService backups;
  final FileSelectorAdapter files;
  final DataErasureService? erasure;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

final class _BackupPageState extends State<BackupPage> {
  final _confirmation = TextEditingController();
  bool _busy = false;
  String? _status;
  String? _error;

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function() operation) async {
    setState(() {
      _busy = true;
      _status = null;
      _error = null;
    });
    try {
      final message = await operation();
      if (mounted && message != null) setState(() => _status = message);
    } on BackupValidationException catch (error) {
      if (mounted) setState(() => _error = '备份验证失败：${error.code}');
    } catch (error) {
      if (mounted) setState(() => _error = '操作失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _create() async {
    final path = await widget.files.chooseBackupDestination();
    if (path == null) return '已取消创建备份。';
    final manifest = await widget.backups.create(path);
    return '备份已创建（数据库格式 v${manifest.schemaVersion}）\n$path';
  }

  Future<String?> _restore() async {
    final path = await widget.files.chooseBackupSource();
    if (path == null) return '已取消恢复。';
    final manifest = await widget.backups.validate(path);
    if (!mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复这份备份？'),
        content: Text(
          '已通过哈希和数据库完整性验证。恢复后将替换当前本地数据库。\n'
          '备份创建于 ${manifest.createdAtUtc.toLocal()}。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (confirmed != true) return '已取消恢复。';
    await widget.backups.restore(path);
    return '恢复完成。';
  }

  Future<void> _erase() async {
    final service = widget.erasure;
    if (service == null) return;
    await _run(() async {
      final result = await service.eraseAll(_confirmation.text);
      if (result == ErasureStatus.confirmationMismatch) {
        return '确认短语不匹配，没有删除任何数据。';
      }
      _confirmation.clear();
      // **必须说"重启后生效"**：删除安排在下次启动执行（运行中的数据库连接仍指向那个文件），
      // 说成"已清除"而用户重启前还能看到数据，就是在用一句好听的话掩盖真实行为。
      return '已安排永久清除：本机应用数据将在**下次启动**时删除；'
          '自行导出的外部文件不在清除范围内。';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('备份与数据安全')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('备份与恢复', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text('恢复前会验证版本、文件长度、SHA-256 哈希和 SQLite 完整性。'),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _run(_create),
              icon: const Icon(Icons.backup_outlined),
              label: const Text('创建备份'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : () => _run(_restore),
              icon: const Icon(Icons.restore_outlined),
              label: const Text('验证并恢复'),
            ),
          ],
        ),
        if (_busy) ...[
          const SizedBox(height: 20),
          const LinearProgressIndicator(),
        ],
        if (_status != null) ...[
          const SizedBox(height: 16),
          SelectableText(_status!),
        ],
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (widget.erasure != null) ...[
          const Divider(height: 48),
          Text('永久清除', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          // **文案要点明两件事**：① 清除范围（外部导出文件不在其中——那是用户自己的文件）；
          // ② **重启后生效**——删除发生在下次启动、没有数据库连接的时候，不写清楚，用户会以为
          // 点了没反应。原先这里还写着"备份索引"，而生产里根本没有备份索引这个东西（见
          // `buildDataErasureService` 的说明），因此从文案里去掉，不留一句做不到的承诺。
          const Text(
            '此操作清除本机数据库、通知与应用锁凭据，但不会删除自行导出的外部文件。'
            '清除在**下次启动**时执行，因此需要重启程序才会看到数据被清空。',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('erasure-confirmation'),
            controller: _confirmation,
            decoration: const InputDecoration(
              labelText: '输入确认短语',
              helperText: DataErasureService.confirmationPhrase,
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              key: const Key('erasure-submit'),
              onPressed: _busy ? null : _erase,
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('永久清除本机数据'),
            ),
          ),
        ],
      ],
    ),
  );
}
