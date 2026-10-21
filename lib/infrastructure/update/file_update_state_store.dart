// 状态文件存储（规格 §9.4 / UPD-019；1.11.1 修复 §4.5）。
//
// 保存走"临时文件 + flush + 原子替换"；读取失败**不抛出**，而是返回一个全新状态并置上
// [lastLoadWasCorrupt]，让编排器先盘点文件再重建，而不是按半份状态去安装。
//
// 1.11.1 的两条新规则：
//   · v1 文件走**显式迁移**而不是"解析失败就重置"（UPD-INC-027）；
//   · 读到未来版本 schema 时**不覆盖原文件**，并把 [sawFutureSchema] 置真，
//     让编排器进入"请先升级客户端"的安全禁用状态。
import 'dart:io';

import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';

final class FileUpdateStateStore implements UpdateStateStore {
  FileUpdateStateStore({required this.file});

  final File file;

  /// 最近一次 [load] 是否读到了存在但无法解释的内容。
  bool lastLoadWasCorrupt = false;

  /// 最近一次 [load] 是否把 v1 文件迁移成了 v2（`true` 时调用方应尽快写回）。
  bool lastLoadMigrated = false;

  bool _sawFutureSchema = false;

  @override
  bool get sawFutureSchema => _sawFutureSchema;

  @override
  Future<UpdateState> load() async {
    lastLoadWasCorrupt = false;
    lastLoadMigrated = false;
    _sawFutureSchema = false;
    if (!await file.exists()) return const UpdateState();
    final json = await readJsonOrNull(file);
    if (json is! Map) {
      lastLoadWasCorrupt = true;
      return const UpdateState();
    }

    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is int && schemaVersion > updateStateSchemaVersion) {
      // 未来版本客户端写的状态：**不解析、不覆盖**。
      _sawFutureSchema = true;
      return const UpdateState();
    }

    final current = UpdateState.tryParse(json);
    if (current != null) return current;

    final migrated = UpdateState.tryMigrateV1(json);
    if (migrated != null) {
      lastLoadMigrated = true;
      // 迁移结果立即原子写回 v2；写失败不影响本次会话使用迁移后的内存状态。
      try {
        await writeJsonAtomically(file, migrated.toJson());
      } on Object {
        // 下次启动会再迁移一次，迁移是幂等的。
      }
      return migrated;
    }

    lastLoadWasCorrupt = true;
    return const UpdateState();
  }

  @override
  Future<void> save(UpdateState state) async {
    if (_sawFutureSchema) {
      // 拒绝用降级解析的结果覆盖未来版本的状态文件。
      throw StateError('UPDATE_STATE_SCHEMA_UNSUPPORTED');
    }
    await writeJsonAtomically(file, state.toJson());
  }

  @override
  Future<void> reset() async {
    lastLoadWasCorrupt = false;
    lastLoadMigrated = false;
    _sawFutureSchema = false;
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // 删除失败与"下次保存覆盖"等价，不阻止重建。
    }
  }
}
