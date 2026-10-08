// Task 12A Step 6（用户 2026-10-08 的接口决定）：标题查询端口。
//
// **为什么标题不进 `UnscheduledTask`**（排程引擎的输出）：引擎只需要任务约束，不该依赖数据库或
// 界面文案；标题可能被用户随时修改，把它固化进引擎输出就成了一份旧快照——用户改了标题，预览里
// 却还是上一个名字。固定日程与周期实例以后也可以各自提供标题查询实现，端口留在这里就够。
//
// **为什么必须有批量接口**：预览一次要为一整份提案里的所有未安排任务取标题。逐条查询在真实
// 数据库上就是 N 次往返，而这个列表的长度由用户的任务数决定。
abstract interface class TaskTitleLookup {
  /// 单个查询。查不到时返回 `null`——调用方负责回落到"未命名任务"，**不得退回裸 UUID**。
  Future<String?> titleFor(String taskId);

  /// 批量查询。返回的 map **只包含查得到的 id**；查不到的由调用方补默认名。
  Future<Map<String, String>> titlesFor(Iterable<String> taskIds);
}
