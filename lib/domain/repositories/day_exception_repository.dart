import 'package:personal_planner/domain/models/day_exception.dart';

/// 特殊日的读取、保存与撤销端口（规范 §8.1）。
///
/// **不提供删除**：撤销是状态变更，审计记录必须保留；数据清除走用户主动的
/// 全量清除流程，而不是本端口。
abstract interface class DayExceptionRepository {
  /// 某本地日**已确认**的特殊日；没有则返回 `null`。
  Future<DayException?> findConfirmed(DateTime localDate);

  /// 作用于 [localDate] 的全部已确认事实：当日特殊日 + 把该日作为恢复日的记录。
  Future<List<DayException>> listAffecting(DateTime localDate);

  /// 本地日期落在 `[first, last]` 闭区间内的全部状态记录，按稳定顺序排列。
  Future<List<DayException>> listBetween(DateTime first, DateTime last);

  /// 新增或按 ID 覆盖保存。草稿、确认、过期都由调用方给出。
  Future<void> save(DayException value);

  /// 把一条记录改为 `revoked`，保留原值并写入撤销时刻。
  Future<void> revoke(String id, DateTime revokedAtUtc);
}
