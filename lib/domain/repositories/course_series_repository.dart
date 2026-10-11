import 'package:personal_planner/domain/models/course_series.dart';

/// 课程管理的**只读端口**（1.8.0，设计规范 §10.3）。
///
/// **为什么要有它，而不是让页面直接查 Drift**：聚合一门课的多个系列片段需要知道
/// `logicalCourseId`、重复规则、单双周的 `intervalWeeks` 与学期归属——这些都是持久化细节。
/// 页面认识它们，就等于把"库长什么样"写进界面，日后改表结构要同时改界面。
///
/// 写操作**不在这里**：它们由 `CourseManagementService` 编排并复用既有的日历系列改写与
/// 导入回滚事务（规范 §10.3 最后一句）。
abstract interface class CourseSeriesRepository {
  /// 按学期列出全部逻辑课程；[termId] 为空时列出所有学期的。
  ///
  /// **只列课表导入来的课程**：手工建的固定日程没有 `logicalCourseId`，
  /// 它们属于日历而不是"课程管理"（Task 9 Step 1 明确要求"普通手工固定日程不出现"）。
  Future<List<CourseSeriesSummary>> listCourses({String? termId});

  /// 一门课的详情（含全部系列片段）。课程不存在时返回 `null`。
  Future<CourseSeriesDetail?> findCourse(String logicalCourseId);

  /// 当前学期 id；没有可判定的当前学期时返回 `null`。
  ///
  /// 放在端口上而不是让页面自己算：判定"现在属于哪个学期"要读学业日历
  /// （第一周周一 ＋ 总周数），那是仓储侧的事实。
  Future<String?> currentTermId();
}
