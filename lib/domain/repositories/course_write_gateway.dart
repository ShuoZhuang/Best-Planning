import 'package:personal_planner/domain/models/course_edit.dart';
import 'package:personal_planner/domain/models/course_series.dart';

/// 课程管理需要的**写入**端口（1.8.0，设计规范 §10.2）。
///
/// **为什么不是直接复用 `CalendarEventDeletion`**：那个端口的 `deleteEvent` 只删锚点行。
/// "删除整个课程"要删的是**多个系列片段 ＋ 它们各自的例外行**，而且必须**在一个事务里**——
/// 删掉一半会让某个片段留下一批再也访问不到、却还在展开器里生效的例外行。
/// 让 `deleteEvent` 去承担这件事会把"删一条"与"删一门课"两种语义混在一个方法里。
///
/// 端口只暴露"按 id 集合做一次事务性清理"这一个动作，范围解析与冲突预览留在服务层。
abstract interface class CourseWriteGateway {
  /// 在一个事务里删除这些锚点，**连同它们各自的例外行**，并把受影响批次标记为
  /// 部分删除。
  ///
  /// ## 事务内的固定顺序（计划 §2.3）
  ///
  /// 1. 读取目标锚点，收集**真实存在**的锚点 id、候选规则 id 与非空批次 id；
  /// 2. 删除 `exception_of_id` 指向目标锚点的例外；
  /// 3. 删除目标锚点；
  /// 4. 对候选规则逐个确认**已经没有任何** `calendar_events.recurrence_rule_id` 引用，
  ///    再删除规则——规则可以被多条锚点共享，不查引用就删会打断别的片段；
  /// 5. 把受影响且当前为 `committed` 的批次改为 `partiallyDeleted`，
  ///    写同一个 [deletedAtUtc]；
  /// 6. 返回实际删除的锚点、例外、规则与受影响批次数。
  ///
  /// **为什么第 1 步必须先读**：调用方传来的 id 可能已经不存在（过期的视图）。
  /// 不先读就无法区分"删掉了 3 条"与"3 个 id 里只有 1 个是真的"，
  /// 更糟的是会**用不存在的 id** 去标记批次状态——那是把别人的数据标成"被删过"。
  ///
  /// **幂等**：空集合、不存在的 id、第二次调用都返回 [CourseDeletionResult.empty]，
  /// 且**不更新批次的 `updated_at_utc`**（否则一次无操作会看起来像一次真实变更）。
  ///
  /// **失败即整体回滚**：任一步抛错时锚点、例外、规则与批次状态全部保持原样。
  Future<CourseDeletionResult> deleteSeriesWithExceptions({
    required Set<String> anchorEventIds,
    required DateTime deletedAtUtc,
  });

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
  /// - [provenance]：**全部最终锚点**共同写下去的来源事实（计划 §2.1／Task 6 Step 5）。
  ///
  /// ## 为什么来源是参数而不是"沿用既有行"
  ///
  /// 修复前这里按 `existingRow == null` 决定来源：复用锚点保留旧的、新增锚点写成
  /// `manual` + `importBatchId: null`。于是给一门导入课程新增一个片段就会造出
  /// **混合来源**，而那一段还可能因为排序靠前让整门课从当前学期列表里消失，
  /// 并且逃出原批次的撤销范围（C16、C17、C18）。
  ///
  /// 来源因此由**服务层按当前库里全部片段解析一次**、由仓储对每个最终锚点统一写入：
  /// 新增片段、复用片段和只改资料的片段遵守同一条规则（§3.1）。
  ///
  /// 非法组合（`timetableImport` + 空批次、`manual` + 非空批次）必须在进入事务前
  /// 抛 [ArgumentError]——那是编程错误，不是用户数据问题。
  Future<void> replaceCourseSeries({
    required List<CourseWriteRow> rows,
    required CourseProfileDraft profile,
    required String zoneId,
    required DateTime updatedAtUtc,
    required CourseSeriesProvenance provenance,
  });

  /// 某个锚点名下的**例外行条数**（删除前的影响预览要用，计划 Task 4 Step 2）。
  ///
  /// 单独一个方法而不是让调用方自己读：例外行的过滤条件是**仓储的实现细节**
  /// （`exception_of_id` 指向本锚点，且要排除零长度的"删除例外"或包含它，
  /// 取决于问的是什么）。把它放在端口上，判据就只有一个来源。
  Future<int> countExceptions(String anchorEventId);

  /// **锚点保留、但已经不再属于新规则的例外条数**（计划 §2.5／Task 8 Step 3）。
  ///
  /// 与 [countExceptions] 是**两件事**，不能相加成一个数字糊过去：
  ///
  /// - `countExceptions`：整段被删除，它名下**全部**例外随之消失；
  /// - 本方法：锚点还在，但缩短周次／改星期／改单双周之后，有些例外落在新规则之外。
  ///
  /// 用户要看到的是两句不同的话——"删除 1 个课程片段及其 2 次单独调整"与
  /// "另有 1 次单独调整已超出新周次，将删除"（§2.5 的文案要求）。
  ///
  /// **它必须是只读的**：预览不得执行删除。判定必须与展开器共用同一个
  /// `recurrenceIncludesLocalDate()`，否则预览报的数字与保存真正删的行数会不一致。
  /// 锚点不存在时返回 0。
  Future<int> countExceptionsInvalidatedBy({
    required String anchorEventId,
    required CourseScheduleDraft replacement,
    required String zoneId,
  });
}
