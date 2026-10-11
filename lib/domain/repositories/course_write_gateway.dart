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
}
