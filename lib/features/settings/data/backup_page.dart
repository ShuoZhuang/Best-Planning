import 'package:flutter/material.dart';
import 'package:personal_planner/application/backup_service.dart';
import 'package:personal_planner/application/data_erasure_service.dart';
import 'package:personal_planner/platform/files/file_selector_adapter.dart';
import 'package:personal_planner/platform/windows/app_restart.dart';

/// 操作失败时给用户看的那句话（M9 补）。
///
/// **修的是什么**：这里原来是 `'操作失败：$error'` —— 把异常对象**原样**打进界面。
/// `BackupService` 自己抛的都是结构化的 `BackupValidationException`（只有 `code`，没有路径），
/// 那条分支是安全的；但**兜底分支**接的是任意异常：文件被占用、磁盘满、路径无权限这类问题
/// 会以 `FileSystemException` / `PathAccessException` 的形式冒出来，而 Dart 这些异常的
/// `toString()` **带着完整路径**，例如
/// `FileSystemException: Cannot open file, path = 'F:\Documents\personal_planner.sqlite' (OS Error: 拒绝访问。, errno = 5)`。
/// 那句话会连同用户的目录结构一起出现在界面上——**导出页已经刻意避免这件事**
/// （`ExportWriteException` 干脆不带任何字段），备份页此前没有。
///
/// **做法**：把绝对路径从消息里替换成人话占位，其余信息保留（用户仍能看出是"拒绝访问"还是
/// "磁盘空间不足"）。这样既不再泄漏路径，也不像"操作失败，请重试"那样把有用信息一起丢掉。
String backupFailureMessage(Object error) {
  final sanitized = _redactPaths('$error');
  return '操作失败：$sanitized';
}

/// 带引号的绝对路径（Dart 异常的常见写法：`path = '...'` 或 `copy from '...'`）。
///
/// **为什么单独一条**：路径里的空格无法与"路径结束后的普通文字"区分开
/// （`'C:\a b\x' failed` 里 ` failed` 到底算不算路径？），因此带引号的形式**以引号为界**，
/// 拿到的是最准确的结果。替换时**连引号一起换掉**，否则会剩下两个孤零零的引号。
final _quotedPath = RegExp("(?:[A-Za-z]:\\\\|\\\\\\\\)[^']*'");

/// 不带引号的绝对路径：盘符（`C:\`）或 UNC（`\\server\share`）开头，
/// 后面接一个**不含分号、不含引号**的片段。
///
/// **为什么按分号断开**：`C:\a\b;C:\c\d` 是"两个路径"，而 `C:\a b\c` 是"一个带空格的路径"。
/// 用分号（以及逗号、右括号）当分隔符是两者之间最稳的折中：宁可少吞一点，
/// 也不要把用户目录后面那句解释性文字一起删掉。
final _barePath = RegExp(
  r'(?:[A-Za-z]:\\|\\\\)[^;,()'
  '\r\n]*',
);

String _redactPaths(String message) {
  var result = message.replaceAll(_quotedPath, '（用户选择的文件）');
  result = result.replaceAll(_barePath, '（用户选择的位置）');
  // 路径被拿掉之后会出现连续空格与悬空的标点，收一下：
  // `copy from  to  failed` → `copy from to failed`。
  return result
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .replaceAll(RegExp(r'\s+([,.;])'), r'$1')
      .trim();
}

final class BackupPage extends StatefulWidget {
  const BackupPage({
    required this.backups,
    required this.files,
    this.erasure,
    this.restart,
    super.key,
  });

  final BackupService backups;
  final FileSelectorAdapter files;
  final DataErasureService? erasure;

  /// 重启应用的方式。默认真的重启；测试注入替身，以免用例把测试进程自己退出掉。
  final Future<void> Function()? restart;

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
      if (mounted) setState(() => _error = backupFailureMessage(error));
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
    final restarted = await _offerRestart(
      title: '恢复已完成',
      message: '恢复会在下次启动时生效。现在重启，还是稍后自己重启？',
    );
    return restarted ? '恢复完成，正在重启…' : '恢复完成，重启后生效。';
  }

  /// 恢复／清除完成后的收尾：问"现在重启还是过会儿"。
  ///
  /// 这两件事都**只在下次启动生效**（运行中的 drift 连接仍指向旧文件），所以必须给出重启入口，
  /// 而不是只留一句"重启后生效"让用户自己去关窗口。返回是否已触发重启。
  Future<bool> _offerRestart({
    required String title,
    required String message,
  }) async {
    if (!mounted) return false;
    final restartNow = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('restore-restart-dialog'),
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            key: const Key('restart-later'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('过会儿再重启'),
          ),
          FilledButton(
            key: const Key('restart-now'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('现在重启'),
          ),
        ],
      ),
    );
    if (restartNow != true) return false;
    await (widget.restart ?? restartApp)();
    return true;
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
      // 与恢复同一条收尾：给出"现在重启"的入口，而不是让用户自己去找。
      final restarted = await _offerRestart(
        title: '清除已安排',
        message: '本机应用数据会在下次启动时删除。现在重启，还是稍后自己重启？',
      );
      if (restarted) return '正在重启，重启后本机数据即被清除。';
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
