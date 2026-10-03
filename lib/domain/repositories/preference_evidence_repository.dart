import 'package:personal_planner/domain/services/preference_analyzer.dart';

/// 偏好证据的读写端口（FR-PREF-01「学习…有效时段、实际专注长度…」）。
///
/// `preference_evidence` 表从 schema v1 就在，`RuleBasedPreferenceAnalyzer` 也一直在消费
/// 这个类型，但**没有任何代码向表里写过一行**：`PreferenceEvidence` 在 `lib/` 中零构造，
/// 因此偏好学习既没有输入，也无从谈"可追溯"（FR-PREF-08）。
abstract interface class PreferenceEvidenceRepository {
  /// 追加一条证据。证据是**只增不改**的观察记录，因此没有更新语义。
  Future<void> save(PreferenceEvidence evidence);

  /// 返回观察时刻不早于 [sinceUtc] 的证据，按观察时刻升序。
  ///
  /// 分析器需要按天与按时段分桶统计（同一 subjectKey 至少 20 条、跨 14 天才生成建议），
  /// 因此读取端只需要一个时间窗口，不需要按 kind 过滤——过滤属于分析器。
  Future<List<PreferenceEvidence>> since(DateTime sinceUtc);
}
