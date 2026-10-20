import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/models/task.dart';

/// 任务排程相关字段的确定序列化哈希（规范 §19.3）。
///
/// **不是 `updatedAtUtc`**：修改一次标题或备注也会推进修改时间，但它不改变"这项任务要排
/// 多少分钟、最早何时能开始"。用修改时间当并发令牌会让合法的开始操作被误判为过期。
///
/// 参与字段与 `RepositoryScheduleProblemSource` 构造 `SchedulableTask` 时读取的字段一致。
String executionTaskInputHash(PlannerTask task) {
  final canonical = {
    'id': task.id,
    'priority': task.priority.name,
    'estimatedMinutes': task.estimatedMinutes,
    'remainingMinutes': task.remainingMinutes,
    'dueAtUtc': task.dueAtUtc?.toUtc().microsecondsSinceEpoch,
    'availableFromUtc': task.availableFromUtc?.toUtc().microsecondsSinceEpoch,
    'energyLevel': task.energyLevel.name,
    'splitMode': task.splitMode.name,
    'minChunkMinutes': task.minChunkMinutes,
    'maxChunkMinutes': task.maxChunkMinutes,
    'preferredStartMinute': task.preferredWindow?.startMinute,
    'preferredEndMinute': task.preferredWindow?.endMinute,
    'status': task.status.name,
  };
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}
