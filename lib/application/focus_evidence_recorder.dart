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
  });

  final PreferenceEvidenceRepository evidence;
  final TaskRepository tasks;
  final WorkspaceRepository workspace;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final Clock clock;
  final IdGenerator idGenerator;

  /// 记录一次已结束的专注；返回是否真的写入了（任务无归属领域时为 false）。
  Future<bool> recordCompletedFocus(FocusSession session) async {
    final subjectKey = await _subjectKeyFor(session.taskId);
    if (subjectKey == null) return false;

    final localStart = zones.toLocal(session.startedAtUtc, timeZoneId);
    final minutes = session.activeDuration.inMinutes;
    await evidence.save(
      PreferenceEvidence(
        id: idGenerator.next(),
        kind: PreferenceEvidenceKind.focusCompletion,
        subjectKey: subjectKey,
        observedAtUtc: clock.nowUtc(),
        numericValue: minutes.toDouble(),
        // FR-PREF-07 要求特殊日降低权重或排除。专注流程目前不知道当天是否是特殊日，
        // 因此一律按普通日记录；这一点登记为缺口而不是猜一个值。
        specialDay: false,
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
