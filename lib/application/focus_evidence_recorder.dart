import 'package:personal_planner/application/focus_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/preference_evidence_repository.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

/// 把"一次专注结束"变成一条偏好证据（FR-PREF-01 的"有效时段"与"实际专注长度"）。
///
/// 存在的理由是学习闭环此前**输入端为零**：`RuleBasedPreferenceAnalyzer` 一直在按
/// subjectKey 与时段分桶统计，却从来没有任何代码写过证据。这里按分析器已经约定的形式写入
/// （subjectKey 形如 `area:<id>`、`metadata['timeBucket']`、`numericValue`），而不是另立一套。
///
/// 两条刻意的取舍，都登记在 §13.0：
/// - `subjectKey` 取任务所属的**领域**：分析器要求同一 subjectKey 至少 20 条、跨 14 天才生成
///   建议，若按任务分组，现实中几乎永远攒不够。因此归属不到领域的任务不写证据——没有可归属
///   的主体时，凭空写一条会让统计把不同性质的行为混在一起。
/// - `numericValue` 取**实际专注分钟数**（FR-PREF-01 的字面要求）。分析器的
///   `difference < 0.15` 阈值是按 0..1 的分数设定的（其测试用 0.9/0.6），对分钟数而言这个
///   门槛实际上形同虚设。这里不擅自改分析器阈值（那是独立决策），但把该失配记下来。
final class FocusEvidenceRecorder {
  const FocusEvidenceRecorder({
    required this.evidence,
    required this.tasks,
    required this.workspace,
    required this.zones,
    required this.timeZoneId,
    required this.clock,
    required this.idGenerator,
    this.isSpecialDay,
  });

  final PreferenceEvidenceRepository evidence;
  final TaskRepository tasks;
  final WorkspaceRepository workspace;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final Clock clock;
  final IdGenerator idGenerator;

  /// 某个**本地日**是否为"特殊日"（FR-PREF-07）。为空时一律按普通日记录。
  ///
  /// **此前这里是硬编码的 `specialDay: false`**，而分析器 `preference_analyzer.dart` 里确有
  /// "排除特殊日证据"的逻辑（`evidence.where((item) => !item.specialDay)`）——于是那条逻辑
  /// **永远筛不掉任何东西**：结构就绪、数据恒为常量、运行期不生效。这与"标签从未被读出"是
  /// 同一类失效，因此这里改成注入一个信号，而不是继续猜一个值。
  ///
  /// **口径**（与 spec §8.9 已写下的那条一致）：**当天存在按日例外**
  /// （`planning.dateOverride.<日期>`，即用户在"临时放宽每日上限"里显式放宽过的那一天）即视为
  /// 特殊日。用回调而不是直接依赖 `SettingsService`：记录器不该知道设置存在哪里，装配由组合根
  /// 负责——与 `FocusService` 的 `onFinished`／`onInterrupted` 同一分工。
  ///
  /// **已知局限，如实记下而不假装覆盖**：其它类型的特殊日——例如通过"特殊日"页声明的晚归／
  /// 加班——目前**没有以"某一天的事实"的形式被持久化**（恢复保护是**提案输入**而不是持久例外，
  /// 见 §13.0 的 C8）。要让那类特殊日也进入排除，得先让它们落地成按日事实。
  final Future<bool> Function(DateTime localDate)? isSpecialDay;

  /// 记录一次已结束的专注；返回是否真的写入了（任务无归属领域时为 false）。
  Future<bool> recordCompletedFocus(FocusSession session) async {
    final subjectKey = await _subjectKeyFor(session.taskId);
    if (subjectKey == null) return false;

    final localStart = zones.toLocal(session.startedAtUtc, timeZoneId);
    final minutes = session.activeDuration.inMinutes;
    // 按**会话开始的那个本地日**判定：跨午夜的专注算在开始那天，与元数据里的
    // `timeBucket`／`startedAtLocalHour` 取自同一时刻，不会出现"时段算今天、特殊日算明天"。
    final localDate = DateTime(
      localStart.year,
      localStart.month,
      localStart.day,
    );
    final specialDay = await isSpecialDay?.call(localDate) ?? false;

    await evidence.save(
      PreferenceEvidence(
        id: idGenerator.next(),
        kind: PreferenceEvidenceKind.focusCompletion,
        subjectKey: subjectKey,
        observedAtUtc: clock.nowUtc(),
        numericValue: minutes.toDouble(),
        // FR-PREF-07 要求特殊日降低权重或排除。
        specialDay: specialDay,
        metadata: {
          'timeBucket': _bucketOf(localStart.hour),
          'minutes': minutes,
          'startedAtLocalHour': localStart.hour,
        },
      ),
    );
    return true;
  }

  Future<String?> _subjectKeyFor(String taskId) async {
    final projectId = (await tasks.getById(taskId))?.projectId;
    if (projectId == null) return null;
    final project = (await workspace.listProjects())
        .where((item) => item.id == projectId)
        .firstOrNull;
    return project == null ? null : 'area:${project.areaId}';
  }

  /// 与既有测试取值一致的三分法（`morning`/`evening` 已在分析器测试中使用）。
  static String _bucketOf(int hour) {
    if (hour >= 5 && hour < 12) return 'morning';
    if (hour >= 12 && hour < 18) return 'afternoon';
    return 'evening';
  }
}
