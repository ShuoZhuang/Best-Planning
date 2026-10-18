import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/repositories/day_exception_repository.dart';
import 'package:personal_planner/domain/repositories/preference_evidence_repository.dart';
import 'package:personal_planner/domain/services/preference_analyzer.dart';

/// 学习证据的**统一写入入口**（算法 20，规范 §9.2；实施计划 Task 4）。
///
/// 相对算法 19 的四条硬性修正：
/// 1. **无领域任务不再静默丢弃**：`subjectKey` 落到 `global`，但全局样本不会反推
///    某个领域的偏好（快照层只把它当无领域任务的回退）。
/// 2. **写入整数效果分**（`0..1000`）而不是把分钟当百分比；旧证据保留但标记为
///    `legacyInsufficientMetric`，不参与新分析。
/// 3. **时段桶**严格按 `morning 05–12 / afternoon 12–18 / evening 18–23 /
///    night 23–05`；跨桶会话按实际分钟拆分，占比最大的桶胜出，平局取时间更早的桶。
/// 4. 特殊日、临时延长日与恢复日样本默认排除，并在元数据里记录排除原因。
final class PreferenceEvidenceService {
  const PreferenceEvidenceService({
    required this.evidence,
    required this.clock,
    required this.zones,
    required this.timeZoneId,
    required this.idGenerator,
    this.dayExceptions,
  });

  final PreferenceEvidenceRepository evidence;
  final Clock clock;
  final TimeZoneDatabase zones;
  final String timeZoneId;
  final IdGenerator idGenerator;
  final DayExceptionRepository? dayExceptions;

  /// 记录一次专注结果（完成或中断）。
  Future<void> recordFocusOutcome({
    required DateTime startedAtUtc,
    required DateTime endedAtUtc,
    required int plannedMinutes,
    required int actualFocusMinutes,
    required int completedMinutes,
    required int pauseMinutes,
    required int interruptionCount,
    required bool completed,
    String? areaId,
    String? taskId,
    String source = 'focus',
  }) async {
    _requireUtc(startedAtUtc, 'startedAtUtc');
    _requireUtc(endedAtUtc, 'endedAtUtc');
    final localStart = _localDateOf(startedAtUtc);
    final localEnd = _localDateOf(endedAtUtc);
    final exclusion = await _exclusionFor(localStart, localEnd);
    final bucket = dominantBucket(
      startedAtUtc: startedAtUtc,
      endedAtUtc: endedAtUtc,
      zones: zones,
      timeZoneId: timeZoneId,
    );
    final effect = focusEffectScore(
      plannedMinutes: plannedMinutes,
      actualFocusMinutes: actualFocusMinutes,
      completedMinutes: completedMinutes,
      interruptionCount: interruptionCount,
    );
    final subjectKey = _subjectKey(areaId);
    await evidence.save(
      PreferenceEvidence(
        id: idGenerator.next(),
        kind: PreferenceEvidenceKind.focusCompletion,
        subjectKey: subjectKey,
        observedAtUtc: clock.nowUtc(),
        numericValue: actualFocusMinutes.toDouble(),
        specialDay: exclusion.excluded,
        metadata: {
          'evidenceVersion': 2,
          'startedAtUtc': startedAtUtc.toIso8601String(),
          'endedAtUtc': endedAtUtc.toIso8601String(),
          'localStart': formatLocalDate(localStart),
          'localEnd': formatLocalDate(localEnd),
          'observedLocalDate': formatLocalDate(localStart),
          'plannedMinutes': plannedMinutes,
          'actualFocusMinutes': actualFocusMinutes,
          'completedMinutes': completedMinutes,
          'pauseMinutes': pauseMinutes,
          'interruptionCount': interruptionCount,
          'completed': completed,
          'effectScorePermille': effect,
          'timeBucket': bucket.bucket.name,
          'bucketMinutes': bucket.minutes,
          'excludedReason': exclusion.reason,
          'sourceVersion': 2,
          'source': source,
          'areaId': ?areaId,
          'taskId': ?taskId,
        },
      ),
    );
  }

  /// 记录一次**用户手动移动**（成功应用后才写）。
  Future<void> recordManualMove({
    required DateTime fromUtc,
    required DateTime toUtc,
    String? areaId,
    String? taskId,
    String source = 'calendar',
  }) async {
    _requireUtc(fromUtc, 'fromUtc');
    _requireUtc(toUtc, 'toUtc');
    final fromLocal = zones.toLocal(fromUtc, timeZoneId);
    final toLocal = zones.toLocal(toUtc, timeZoneId);
    await evidence.save(
      PreferenceEvidence(
        id: idGenerator.next(),
        kind: PreferenceEvidenceKind.manualMove,
        subjectKey: _subjectKey(areaId),
        observedAtUtc: clock.nowUtc(),
        numericValue: (toLocal.hour * 60 + toLocal.minute).toDouble(),
        metadata: {
          'evidenceVersion': 2,
          'taskId': taskId,
          'areaId': areaId,
          'localDate': formatLocalDate(
            DateTime(fromLocal.year, fromLocal.month, fromLocal.day),
          ),
          'fromMinute': fromLocal.hour * 60 + fromLocal.minute,
          'toMinute': toLocal.hour * 60 + toLocal.minute,
          'direction': toLocal.isAfter(fromLocal) ? 'later' : 'earlier',
          'sourceVersion': 2,
          'source': source,
        },
      ),
    );
  }

  /// 记录一次建议动作（接受 / 拒绝 / 停用 / 编辑）。
  Future<void> recordSuggestionAction({
    required String suggestionId,
    required String action,
    required String suggestionKind,
    String? areaId,
    String source = 'preferences_page',
  }) async {
    await evidence.save(
      PreferenceEvidence(
        id: idGenerator.next(),
        kind: PreferenceEvidenceKind.suggestionAction,
        subjectKey: _subjectKey(areaId),
        observedAtUtc: clock.nowUtc(),
        metadata: {
          'evidenceVersion': 2,
          'suggestionId': suggestionId,
          'action': action,
          'suggestionKind': suggestionKind,
          'sourceVersion': 2,
          'source': source,
        },
      ),
    );
  }

  Future<_Exclusion> _exclusionFor(DateTime start, DateTime end) async {
    final repository = dayExceptions;
    if (repository == null) return const _Exclusion(false, null);
    final affected = <DayException>[];
    for (var date = start; !date.isAfter(end); date = _next(date)) {
      affected.addAll(await repository.listAffecting(date));
    }
    if (affected.isEmpty) return const _Exclusion(false, null);
    final special = affected.any((item) => item.localDate == start);
    final recovery = affected.any((item) => item.recoveryLocalDate == start);
    if (special) return const _Exclusion(true, 'specialDay');
    if (recovery) return const _Exclusion(true, 'recoveryDay');
    return const _Exclusion(true, 'specialDay');
  }

  DateTime _localDateOf(DateTime instantUtc) {
    final local = zones.toLocal(instantUtc, timeZoneId);
    return DateTime(local.year, local.month, local.day);
  }

  static String _subjectKey(String? areaId) =>
      areaId == null || areaId.isEmpty ? 'global' : 'area:$areaId';

  static DateTime _next(DateTime date) =>
      DateTime(date.year, date.month, date.day + 1);

  static void _requireUtc(DateTime value, String name) {
    if (!value.isUtc) {
      throw ArgumentError.value(value, name, '必须是 UTC 时刻');
    }
  }
}

final class _Exclusion {
  const _Exclusion(this.excluded, this.reason);
  final bool excluded;
  final String? reason;
}

enum TimeBucket { morning, afternoon, evening, night }

final class DominantBucket {
  const DominantBucket({required this.bucket, required this.minutes});
  final TimeBucket bucket;
  final Map<String, int> minutes;
}

/// 按**实际分钟**把会话拆分到四个本地时段桶，返回占比最大的桶。
///
/// 边界固定为：`morning [05:00,12:00)`、`afternoon [12:00,18:00)`、
/// `evening [18:00,23:00)`、`night [23:00,05:00)`。平局按时间先后取更早的桶。
DominantBucket dominantBucket({
  required DateTime startedAtUtc,
  required DateTime endedAtUtc,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  final start = zones.toLocal(startedAtUtc, timeZoneId);
  final end = zones.toLocal(endedAtUtc, timeZoneId);
  final totals = <TimeBucket, int>{
    for (final bucket in TimeBucket.values) bucket: 0,
  };
  var cursor = DateTime(
    start.year,
    start.month,
    start.day,
    start.hour,
    start.minute,
  );
  var guard = 0;
  while (cursor.isBefore(end) && guard++ < 10000) {
    final nextBoundary = _nextBoundary(cursor);
    final segmentEnd = nextBoundary.isBefore(end) ? nextBoundary : end;
    final minutes = segmentEnd.difference(cursor).inMinutes;
    if (minutes > 0) {
      final bucket = bucketForMinuteOfDay(cursor.hour * 60 + cursor.minute);
      totals[bucket] = totals[bucket]! + minutes;
    }
    if (!segmentEnd.isAfter(cursor)) break;
    cursor = segmentEnd;
  }
  var best = TimeBucket.morning;
  var bestMinutes = -1;
  for (final bucket in TimeBucket.values) {
    if (totals[bucket]! > bestMinutes) {
      best = bucket;
      bestMinutes = totals[bucket]!;
    }
  }
  return DominantBucket(
    bucket: best,
    minutes: {for (final entry in totals.entries) entry.key.name: entry.value},
  );
}

TimeBucket bucketForMinuteOfDay(int minute) {
  if (minute >= 5 * 60 && minute < 12 * 60) return TimeBucket.morning;
  if (minute >= 12 * 60 && minute < 18 * 60) return TimeBucket.afternoon;
  if (minute >= 18 * 60 && minute < 23 * 60) return TimeBucket.evening;
  return TimeBucket.night;
}

DateTime _nextBoundary(DateTime local) {
  final minute = local.hour * 60 + local.minute;
  const boundaries = [5 * 60, 12 * 60, 18 * 60, 23 * 60];
  for (final boundary in boundaries) {
    if (boundary > minute) {
      return DateTime(
        local.year,
        local.month,
        local.day,
        boundary ~/ 60,
        boundary % 60,
      );
    }
  }
  return DateTime(local.year, local.month, local.day + 1, 5);
}

/// 专注会话的**整数效果分**（`0..1000`）。
///
/// 四个分项都是固定整数公式，避免平台浮点差异：
/// - 完成比例：`completed / planned`；
/// - 有效专注比例：`actualFocus / planned`；
/// - 计划偏差：`1 - |planned - actualFocus| / planned`；
/// - 中断惩罚：每次中断扣 100，上限 1000。
///
/// 权重为 40% / 30% / 20% / 10%，全部整数四舍五入。原始分钟**永远不直接**当成
/// 百分比或效果差（规范 §9.3 / ALG20-058）。
int focusEffectScore({
  required int plannedMinutes,
  required int actualFocusMinutes,
  required int completedMinutes,
  required int interruptionCount,
}) {
  if (plannedMinutes <= 0) return 0;
  final completion = _clamp1000(completedMinutes * 1000 ~/ plannedMinutes);
  final effective = _clamp1000(actualFocusMinutes * 1000 ~/ plannedMinutes);
  final deviation = _clamp1000(
    1000 -
        ((plannedMinutes - actualFocusMinutes).abs() * 1000 ~/ plannedMinutes),
  );
  final interruption = _clamp1000(1000 - interruptionCount * 100);
  final weighted =
      completion * 400 + effective * 300 + deviation * 200 + interruption * 100;
  return _clamp1000((weighted + 500) ~/ 1000);
}

int _clamp1000(int value) => value < 0 ? 0 : (value > 1000 ? 1000 : value);
