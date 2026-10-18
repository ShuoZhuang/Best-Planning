// 状态文件存储（规格 §9.4 / UPD-019）。
//
// 保存走"临时文件 + flush + 原子替换"；读取失败**不抛出**，而是返回一个全新状态并置上
// [lastLoadWasCorrupt]，让编排器先盘点文件再重建，而不是按半份状态去安装。
import 'dart:io';

import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';
import 'package:personal_planner/infrastructure/update/atomic_file.dart';

final class FileUpdateStateStore implements UpdateStateStore {
  FileUpdateStateStore({required this.file});

  final File file;

  /// 最近一次 [load] 是否读到了存在但无法解释的内容。
  bool lastLoadWasCorrupt = false;

  @override
  Future<UpdateState> load() async {
    lastLoadWasCorrupt = false;
    if (!await file.exists()) return const UpdateState();
    final json = await readJsonOrNull(file);
    if (json == null) {
      lastLoadWasCorrupt = true;
      return const UpdateState();
    }
    final state = UpdateState.tryParse(json);
    if (state == null) {
      lastLoadWasCorrupt = true;
      return const UpdateState();
    }
    return state;
  }

  @override
  Future<void> save(UpdateState state) =>
      writeJsonAtomically(file, state.toJson());

  @override
  Future<void> reset() async {
    lastLoadWasCorrupt = false;
    try {
      if (await file.exists()) await file.delete();
    } on Object {
      // 删除失败与"下次保存覆盖"等价，不阻止重建。
    }
  }
}
