// 跨进程更新锁（规格 §15.1 / UPD-021）。
//
// 两层保护：
//   1. **操作系统文件锁**（`LockFileEx`）：进程崩溃时自动释放，不需要"猜陈旧"；
//   2. 锁文件里记录 PID、进程启动时间、事务号、操作类型与目标版本，用于诊断与"PID 复用"判断。
//
// 只有拿到 OS 锁才算持有；文件内容只是描述，不能代替锁。
import 'dart:convert';
import 'dart:io';

import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';

final class FileUpdateLock implements UpdateLock {
  FileUpdateLock({required this.file, required this.processProbe});

  final File file;
  final ProcessIdentityProbe processProbe;

  /// 同进程内的持有表：Windows 的文件锁是**按进程**归属的，两个句柄仍可能都成功，
  /// 因此必须在本进程内再加一层互斥。
  static final Map<String, FileUpdateLock> _heldByPath = {};

  RandomAccessFile? _handle;
  bool _held = false;
  Map<String, Object?>? _record;

  /// 最近一次失败的原始原因（诊断用）。
  Object? lastError;

  @override
  Future<bool> acquire({
    required String transactionId,
    required int pid,
    required DateTime processStartedAtUtc,
    required String token,
    required String operation,
    required String targetVersion,
  }) async {
    if (_held) return true;
    final key = file.absolute.path.toLowerCase();
    if (_heldByPath.containsKey(key)) return false;
    try {
      // PID + 启动时间必须与调用方记录的一致，避免 PID 复用把别人的锁当成自己的。
      final actual = await processProbe.forPid(pid);
      if (actual == null ||
          actual.startedAtUtc.difference(processStartedAtUtc).abs() >
              const Duration(seconds: 2)) {
        return false;
      }
      await file.parent.create(recursive: true);
      final handle = await file.open(mode: FileMode.write);
      try {
        // 非阻塞独占锁：拿不到就说明另一个存活进程正在更新。
        await handle.lock(FileLock.exclusive);
      } on FileSystemException {
        await handle.close();
        return false;
      }
      final record = {
        'schemaVersion': 1,
        'pid': pid,
        'processStartedAtUtc': processStartedAtUtc.toUtc().toIso8601String(),
        'transactionId': transactionId,
        'token': token,
        'operation': operation,
        'targetVersion': targetVersion,
        'acquiredAtUtc': DateTime.now().toUtc().toIso8601String(),
      };
      await handle.truncate(0);
      await handle.setPosition(0);
      await handle.writeString(jsonEncode(record));
      await handle.flush();
      _handle = handle;
      _held = true;
      _record = record;
      _heldByPath[key] = this;
      return true;
    } on FileSystemException catch (error) {
      lastError = error;
      await _closeQuietly();
      return false;
    } on Object catch (error) {
      lastError = error;
      await _closeQuietly();
      return false;
    }
  }

  @override
  Future<LockInspection> inspect() async {
    final key = file.absolute.path.toLowerCase();
    final localHolder = _heldByPath[key];
    if (localHolder != null) {
      return LockInspection.held(
        holderPid: localHolder._record?['pid'] is int
            ? localHolder._record!['pid'] as int
            : null,
        holderStartedAtUtc: _parseUtc(
          localHolder._record?['processStartedAtUtc'],
        ),
        operation: localHolder._record?['operation'] is String
            ? localHolder._record!['operation'] as String
            : null,
      );
    }
    if (!await file.exists()) return const LockInspection.free();
    Map<String, Object?>? record;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) record = decoded.cast<String, Object?>();
    } on Object {
      record = null;
    }
    RandomAccessFile? probe;
    try {
      probe = await file.open(mode: FileMode.append);
      try {
        await probe.lock(FileLock.exclusive);
        // 能拿到锁：没有存活进程持有它（内容可能只是上次崩溃留下的）。
        await probe.unlock();
        return const LockInspection.free();
      } on FileSystemException {
        return LockInspection.held(
          holderPid: record?['pid'] is int ? record!['pid'] as int : null,
          holderStartedAtUtc: _parseUtc(record?['processStartedAtUtc']),
          operation: record?['operation'] is String
              ? record!['operation'] as String
              : null,
        );
      }
    } on Object {
      return const LockInspection.free();
    } finally {
      await probe?.close();
    }
  }

  @override
  Future<void> release() async {
    final handle = _handle;
    _handle = null;
    _held = false;
    _heldByPath.remove(file.absolute.path.toLowerCase());
    if (handle == null) return;
    try {
      await handle.unlock();
    } on Object {
      // 进程退出时 OS 也会释放。
    }
    await handle.close();
    // 锁文件保留为空会误导下一个读者；删除失败也不影响锁已经释放。
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // 忽略。
    }
  }

  bool get isHeld => _held;

  Future<void> _closeQuietly() async {
    final handle = _handle;
    _handle = null;
    _held = false;
    _heldByPath.remove(file.absolute.path.toLowerCase());
    try {
      await handle?.close();
    } on Object {
      // 忽略。
    }
  }

  static DateTime? _parseUtc(Object? raw) {
    if (raw is! String) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// 供诊断面板读取的当前锁内容（可能为 `null`）。
  Future<Map<String, Object?>?> readRecord() async {
    if (_held && _record != null) return _record;
    final value = await readJsonOrNull(file);
    return value is Map ? value.cast<String, Object?>() : null;
  }
}
