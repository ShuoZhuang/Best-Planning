/// 延后的单位（规范 §11.1）。
///
/// **分钟与小时按"经过时长"算，天按"本地日历日"算**——这是规范 §11.2 的分界线，
/// 也是"延后 1 天遇 DST 保持本地钟点"能成立的前提。
///
/// 它现在住在 domain 而不是 `application/pending_moves.dart`：持久化的调整操作
/// （`PlanAdjustment`）要把单位写进数据库，domain 不应反向依赖 application 层。
/// `pending_moves.dart` 原样 re-export，因此既有 import 不需要改动。
enum DeferUnit { minutes, hours, days }
