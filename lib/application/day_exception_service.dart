import 'package:personal_planner/application/settings_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/day_exception.dart';
import 'package:personal_planner/domain/repositories/day_exception_repository.dart';

/// 特殊日校验失败。**带字段**，页面据此决定哪个输入框报错，禁止解析字符串。
final class DayExceptionValidationException implements Exception {
  const DayExceptionValidationException(this.fieldErrors);

  final Map<String, String> fieldErrors;

  @override
  String toString() => 'DayExceptionValidationException($fieldErrors)';
}

/// 特殊日生命周期、配额与连续日校验（规范 §8.2 / 实施计划 Task 3）。
///
/// 服务只写特殊日事实，不生成计划、不读 UI。确认时把"同日旧确认撤销 +
/// 新确认"收敛到一次仓储写入序列；真正的**计划 + 特殊日原子提交**由 Task 12 的
/// `PlanningCommitRepository` 负责，本服务不越界。
final class DayExceptionService {
  DayExceptionService({
    required this.repository,
    required this.settings,
    required this.clock,
    required this.zones,
    required this.timeZoneId,
  });

  final DayExceptionRepository repository;
  final SettingsService settings;
  final Clock clock;
  final TimeZoneDatabase zones;

  /// 目标 IANA 时区。**由组合根注入**，服务不读系统区域、也不从任务行猜测。
  final String timeZoneId;

  /// 同一毫秒内连续创建草稿时的稳定去重序号（ID 不是排程结果，不影响确定性）。
  int _idSequence = 0;

  /// 创建一条**草稿**。草稿不影响排程，必须显式 [confirm] 才生效。
  Future<DayException> createDraft({
    required DateTime localDate,
    required DayExceptionKind kind,
    required int originalSleepStartOffsetMinutes,
    required int temporarySleepStartOffsetMinutes,
    required int fixedWakeOffsetMinutes,
    RecoveryChoice recoveryChoice = RecoveryChoice.none,
    DateTime? recoveryLocalDate,
    String source = 'user',
    String? triggeringProposalId,
    String auditNote = '',
    String? id,
  }) async {
    final date = normalize(localDate);
    _validateLocalDate(date, 'localDate');
    final minimumSleep = await settings.loadAbsoluteMinimumSleepMinutes();
    final now = clock.nowUtc();
    final value = DayException(
      id: id ?? _newId(date, kind, now),
      localDate: date,
      kind: kind,
      status: DayExceptionStatus.draft,
      originalSleepStartOffsetMinutes: originalSleepStartOffsetMinutes,
      temporarySleepStartOffsetMinutes: temporarySleepStartOffsetMinutes,
      fixedWakeOffsetMinutes: fixedWakeOffsetMinutes,
      absoluteMinimumSleepMinutes: minimumSleep,
      recoveryChoice: recoveryChoice,
      source: source,
      createdAtUtc: now,
      updatedAtUtc: now,
      triggeringProposalId: triggeringProposalId,
      recoveryLocalDate: recoveryLocalDate == null
          ? null
          : normalize(recoveryLocalDate),
      auditNote: auditNote,
    );
    await repository.save(value);
    return value;
  }

  /// 确认前的**纯校验**：不写库。
  ///
  /// 供 `SpecialDayPlanningService` 在生成提案前调用；它让"配额 / 连续日 / 最低睡眠"
  /// 的校验只有一份实现，且不会为了校验先写一条草稿。
  Future<void> validateForConfirmation(DayException draft) async {
    if (draft.status == DayExceptionStatus.revoked ||
        draft.status == DayExceptionStatus.expired) {
      throw const DayExceptionValidationException({
        'status': '已撤销或已过期的记录不能再确认',
      });
    }
    final date = normalize(draft.localDate);
    if (draft.kind == DayExceptionKind.temporaryExtensionDay) {
      await _requireExtensionPolicy(date, draft.id);
      await _requireSingleExtensionPerProposal(draft);
    } else {
      await _requireUserDayPolicy(date, draft.id);
    }
    draft.requireMinimumSleep(zones, timeZoneId);
  }

  /// 确认一条草稿；与它同本地日的旧确认记录被撤销。
  ///
  /// 校验顺序固定：最低睡眠 → 连续日 → 滚动配额 → 同日旧记录撤销 → 写入。
  /// 任一步失败都不写库。
  Future<DayException> confirm(DayException draft) async {
    await validateForConfirmation(draft);
    final date = normalize(draft.localDate);

    final now = clock.nowUtc();
    final confirmed = draft.copyWith(
      status: DayExceptionStatus.confirmed,
      updatedAtUtc: now,
    );
    final existing = await repository.findConfirmed(date);
    if (existing != null && existing.id != confirmed.id) {
      await repository.revoke(existing.id, now);
    }
    await repository.save(confirmed);
    return confirmed;
  }

  /// 撤销一条已存在的记录。记录保留，状态与撤销时刻可见。
  Future<DayException> revoke(String id) async {
    final rows = await repository.listBetween(DateTime(1970), DateTime(9999));
    final target = rows.where((item) => item.id == id).firstOrNull;
    if (target == null) {
      throw const DayExceptionValidationException({'id': '记录不存在'});
    }
    if (target.status == DayExceptionStatus.revoked) return target;
    final now = clock.nowUtc();
    await repository.revoke(id, now);
    return target.copyWith(
      status: DayExceptionStatus.revoked,
      updatedAtUtc: now,
      revokedAtUtc: now,
    );
  }

  /// 某本地日进入逐日策略的已确认事实。
  Future<DayException?> confirmedForDate(DateTime localDate) =>
      repository.findConfirmed(normalize(localDate));

  /// 作用于 [localDate] 的全部已确认事实（含恢复日）。
  Future<List<DayException>> affectingDate(DateTime localDate) =>
      repository.listAffecting(normalize(localDate));

  /// 滚动 7 天（含当天）还可提出/采用几次临时延长日。
  Future<int> remainingExtensionQuota(DateTime localDate) async {
    final date = normalize(localDate);
    final quota = await settings.loadWeeklyExtensionQuota();
    final used = await _extensionCountInRollingWeek(date);
    return (quota - used).clamp(0, quota);
  }

  /// 是否允许在 [localDate] 提出新的临时延长日。
  ///
  /// 连续两天、配额用尽、已经存在同日延长日都返回 `false`。**这只是候选前置条件**，
  /// 真正的硬边界（睡眠、截止、固定占用）由 `ExtensionDayPolicy` 判定。
  Future<bool> canProposeExtension(DateTime localDate) async {
    final date = normalize(localDate);
    if (await _extensionCountInRollingWeek(date) >=
        await settings.loadWeeklyExtensionQuota()) {
      return false;
    }
    if (await _hasExtensionOn(date)) return false;
    final previous = DateTime(date.year, date.month, date.day - 1);
    if (await _hasExtensionOn(previous)) return false;
    final next = DateTime(date.year, date.month, date.day + 1);
    if (await _hasExtensionOn(next)) return false;
    return true;
  }

  Future<void> _requireExtensionPolicy(DateTime date, String selfId) async {
    final quota = await settings.loadWeeklyExtensionQuota();
    if (quota == 0) {
      throw const DayExceptionValidationException({
        'localDate': '用户已把临时延长日频率设为 0',
      });
    }
    if (await _extensionCountInRollingWeek(date, excludingId: selfId) >=
        quota) {
      throw DayExceptionValidationException({
        'localDate': '滚动 7 天最多允许 $quota 次临时延长日',
      });
    }
    final previous = DateTime(date.year, date.month, date.day - 1);
    final next = DateTime(date.year, date.month, date.day + 1);
    if (await _hasExtensionOn(previous, excludingId: selfId) ||
        await _hasExtensionOn(next, excludingId: selfId)) {
      throw const DayExceptionValidationException({
        'localDate': '不允许连续两个本地日延长',
      });
    }
  }

  Future<void> _requireUserDayPolicy(DateTime date, String selfId) async {
    // 主动特殊日不占延长日配额，但同日仍只能有一条确认记录——由 confirm 撤销旧记录。
  }

  /// 一份计划至多采用一个临时延长日（规范 §8.2 / ALG20-046）。
  Future<void> _requireSingleExtensionPerProposal(DayException draft) async {
    final proposalId = draft.triggeringProposalId;
    if (proposalId == null || proposalId.isEmpty) return;
    final rows = await repository.listBetween(DateTime(1970), DateTime(9999));
    final existing = rows.where(
      (item) =>
          item.id != draft.id &&
          item.status == DayExceptionStatus.confirmed &&
          item.kind == DayExceptionKind.temporaryExtensionDay &&
          item.triggeringProposalId == proposalId,
    );
    if (existing.isNotEmpty) {
      throw const DayExceptionValidationException({
        'triggeringProposalId': '同一份计划最多采用一个临时延长日',
      });
    }
  }

  Future<int> _extensionCountInRollingWeek(
    DateTime date, {
    String? excludingId,
  }) async {
    final first = DateTime(date.year, date.month, date.day - 6);
    final rows = await repository.listBetween(first, date);
    return rows
        .where(
          (item) =>
              item.id != excludingId &&
              item.status == DayExceptionStatus.confirmed &&
              item.kind == DayExceptionKind.temporaryExtensionDay,
        )
        .length;
  }

  Future<bool> _hasExtensionOn(DateTime date, {String? excludingId}) async {
    final rows = await repository.listBetween(date, date);
    return rows.any(
      (item) =>
          item.id != excludingId &&
          item.status == DayExceptionStatus.confirmed &&
          item.kind == DayExceptionKind.temporaryExtensionDay,
    );
  }

  void _validateLocalDate(DateTime value, String field) {
    if (value.year < 1970 || value.year > 9999) {
      throw DayExceptionValidationException({field: '本地日期超出支持范围'});
    }
  }

  String _newId(DateTime date, DayExceptionKind kind, DateTime now) =>
      'day:${formatLocalDate(date)}:${kind.name}:'
      '${now.microsecondsSinceEpoch}:${_idSequence++}';
}
