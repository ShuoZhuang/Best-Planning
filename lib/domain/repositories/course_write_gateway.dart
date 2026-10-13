import 'package:personal_planner/domain/models/course_edit.dart';

/// 课程管理需要的**写入**端口（1.8.0，设计规范 §10.2）。
///
/// **为什么不是直接复用 `CalendarEventDeletion`**：那个端口的 `deleteEvent` 只删锚点行。
/// "删除整个课程"要删的是**多个系列片段 ＋ 它们各自的例外行**，而且必须**在一个事务里**——
/// 删掉一半会让某个片段留下一批再也访问不到、却还在展开器里生效的例外行。
/// 让 `deleteEvent` 去承担这件事会把"删一条"与"删一门课"两种语义混在一个方法里。
///
/// 端口只暴露"按 id 集合做一次事务性清理"这一个动作，范围解析与冲突预览留在服务层。
abstract interface class CourseWriteGateway {
  /// 在一个事务里删除这些锚点，**连同它们各自的例外行**。
  ///
  /// 幂等：id 不存在就当已经删掉（调用方拿到的 id 可能来自一次已过期的视图）。
  Future<void> deleteSeriesWithExceptions(Set<String> anchorEventIds);

  /// 在**一个事务里**把一门课的安排换成 [rows]（课程与保护时间管理修复计划 Task 4）。
  ///
  /// ## 为什么必须整体替换，而不是"逐段改＋逐段删＋逐段建"
  ///
  /// 编辑页允许用户同时改名、改教师、改星期、改周次、删掉一条、再加一条。逐段操作会有
  /// **中间态**：删掉旧的那一条之后、新的还没建起来之前，这门课在库里是缺了一段课表的。
  /// 那个中间态可能被排程读到（它按 drift 的 watch 重算），于是用户会看到计划里
  /// 少了几次课——而且是在他"只是点了一下保存"的时候。整体替换不存在这个窗口。
  ///
  /// ## 各参数的分工
  ///
  /// - [rows]：**最终形态**。每一行带一个可选的 `reuseAnchorId`——匹配上既有片段时
  ///   沿用它的 id，从而保住它名下**逐次调整过的例外**；不匹配的行按新锚点创建。
  ///   没有出现在 [rows] 里的既有片段会被删除（连同例外）。
  /// - [profile]：整门课的资料。**教师存在 `notes` 列**里（本批次不引入"课程备注"
  ///   这个新概念），因此它随每一行的锚点一起写下去。
  /// - [zoneId]：新锚点的时区。
  /// - [updatedAtUtc]：所有新写入行的 `updated_at_utc`（由服务层的时钟决定，
  ///   仓储不自己取时间——那会让同一次保存里的两行差几毫秒）。
  Future<void> replaceCourseSeries({
    required List<CourseWriteRow> rows,
    required CourseProfileDraft profile,
    required String zoneId,
    required DateTime updatedAtUtc,
  });

  /// 某个锚点名下的**例外行条数**（删除前的影响预览要用，计划 Task 4 Step 2）。
  ///
  /// 单独一个方法而不是让调用方自己读：例外行的过滤条件是**仓储的实现细节**
  /// （`exception_of_id` 指向本锚点，且要排除零长度的"删除例外"或包含它，
  /// 取决于问的是什么）。把它放在端口上，判据就只有一个来源。
  Future<int> countExceptions(String anchorEventId);
}
