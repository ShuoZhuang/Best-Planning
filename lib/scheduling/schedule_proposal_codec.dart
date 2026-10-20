import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:personal_planner/domain/models/time_range.dart';
import 'package:personal_planner/scheduling/adjustment_fulfilment.dart';
import 'package:personal_planner/scheduling/plan_validator.dart';
import 'package:personal_planner/scheduling/search_outcome.dart';
import 'package:personal_planner/scheduling/schedule_problem.dart';
import 'package:personal_planner/scheduling/schedule_proposal.dart';

/// 完整、带版本、可校验哈希的提案持久化编码（计划 Task 3 Step 4）。
///
/// **为什么不能只存块**：确认阶段要复用 `unscheduled`、`conflicts`、`explanations`、
/// `metrics`、`outcome` 与调整要求。从块反推的"看起来可用"的提案会静默丢掉
/// "预算耗尽""未兑现""阻断冲突"等事实，而这些正是应用闸门的判据。
///
/// **为什么 key 与列表都要排序**：同一份提案必须得到同一个哈希。`Map` 的迭代顺序
/// 与对象构造顺序都不是语义，把它们写进哈希会让"内容没变"的提案被判为过期。
final class ScheduleProposalCodec {
  const ScheduleProposalCodec();

  static const int currentFormatVersion = 1;

  String encodeCanonical(ScheduleProposal proposal) =>
      jsonEncode(_canonicalize(_payload(proposal)));

  ScheduleProposal decode(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('提案 JSON 的根必须是对象。');
    }
    final version = decoded['formatVersion'];
    if (version != currentFormatVersion) {
      throw FormatException(
        '未知的提案格式版本：$version（当前支持 $currentFormatVersion）；'
        '拒绝按残缺字段重建"看起来可用"的提案。',
      );
    }
    final body = decoded['proposal'];
    if (body is! Map<String, Object?>) {
      throw const FormatException('提案 JSON 缺少 proposal 对象。');
    }
    return _proposalFrom(body);
  }

  String sha256OfCanonical(ScheduleProposal proposal) =>
      sha256.convert(utf8.encode(encodeCanonical(proposal))).toString();

  // ── 编码 ─────────────────────────────────────────────────────────────────

  Map<String, Object?> _payload(ScheduleProposal proposal) => {
    'formatVersion': currentFormatVersion,
    'proposal': {
      'proposalId': proposal.proposalId,
      'inputHash': proposal.inputHash,
      'algorithmVersion': proposal.algorithmVersion,
      'outcome': proposal.outcome.name,
      'planningWindow': {
        'startUtcMicros': proposal.planningWindow.startUtc.microsecondsSinceEpoch,
        'endUtcMicros': proposal.planningWindow.endUtc.microsecondsSinceEpoch,
      },
      'metrics': {
        'isFullyFeasible': proposal.metrics.isFullyFeasible,
        'scheduledMinutes': proposal.metrics.scheduledMinutes,
        'unscheduledMinutes': proposal.metrics.unscheduledMinutes,
      },
      'blocks': [
        for (final block in [...proposal.blocks]
          ..sort((a, b) => a.id.compareTo(b.id)))
          {
            'id': block.id,
            'taskId': block.taskId,
            'startUtcMicros': block.range.startUtc.microsecondsSinceEpoch,
            'endUtcMicros': block.range.endUtc.microsecondsSinceEpoch,
            'locked': block.locked,
            'explanationCode': block.explanationCode,
            'continuedFromId': block.continuedFromId,
          },
      ],
      'unscheduled': [
        for (final item in [...proposal.unscheduled]
          ..sort((a, b) => a.taskId.compareTo(b.taskId)))
          _unscheduledJson(item),
      ],
      'conflicts': [
        for (final conflict in [...proposal.conflicts]..sort(_conflictOrder))
          _conflictJson(conflict),
      ],
      'explanations': [
        for (final explanation in [...proposal.explanations]
          ..sort((a, b) => a.code.compareTo(b.code)))
          {
            'code': explanation.code,
            'parameters': explanation.parameters,
          },
      ],
      'adjustmentRequirement': _requirementJson(proposal.adjustmentRequirement),
      // `ScheduleRuleOverride` 目前只由特殊日恢复产生，不进入持久调整预览；
      // 真出现时**显式拒绝**，而不是编码成 null 后让确认阶段拿到不同规则。
      'ruleOverride': proposal.ruleOverride == null
          ? null
          : throw UnsupportedError(
              '持久提案暂不支持 ScheduleRuleOverride；请勿把特殊日覆盖提案写入调整预览。',
            ),
    },
  };

  static int _conflictOrder(PlanningConflict a, PlanningConflict b) {
    final byCode = a.code.index.compareTo(b.code.index);
    if (byCode != 0) return byCode;
    return (a.taskId ?? '').compareTo(b.taskId ?? '');
  }

  Map<String, Object?> _unscheduledJson(UnscheduledTask item) => {
    'taskId': item.taskId,
    'shortageMinutes': item.shortageMinutes,
    'primaryReason': _reasonJson(item.primaryReason),
    'reasons': [for (final reason in item.reasons) _reasonJson(reason)],
  };

  Map<String, Object?> _reasonJson(UnscheduledReason reason) => {
    'code': reason.code.name,
    'placementRemainingMinutes': reason.placementRemainingMinutes,
    'constraintRequiredMinutes': reason.constraintRequiredMinutes,
    'constraintAvailableMinutes': reason.constraintAvailableMinutes,
    'constraintLabel': reason.constraintLabel,
  };

  Map<String, Object?> _conflictJson(PlanningConflict conflict) => {
    'code': conflict.code.name,
    'taskId': conflict.taskId,
    'shortageMinutes': conflict.shortageMinutes,
    'invalidInputReason': conflict.invalidInputReason?.name,
    'blockingInput': conflict.blockingInput,
    'relatedEntityIds': conflict.relatedEntityIds,
    'details': conflict.details,
  };

  Map<String, Object?>? _requirementJson(AdjustmentRequirement? value) =>
      value == null
      ? null
      : {
          'targetBlockId': value.targetBlockId,
          'notBeforeUtcMicros': value.notBeforeUtc.microsecondsSinceEpoch,
          'requiredMinutes': value.requiredMinutes,
          'originalStartUtcMicros': value.originalStartUtc.microsecondsSinceEpoch,
        };

  // ── 解码 ─────────────────────────────────────────────────────────────────

  ScheduleProposal _proposalFrom(Map<String, Object?> body) {
    final metrics = _map(body['metrics'], 'metrics');
    final window = _map(body['planningWindow'], 'planningWindow');
    return ScheduleProposal(
      proposalId: _string(body, 'proposalId'),
      inputHash: _string(body, 'inputHash'),
      algorithmVersion: _string(body, 'algorithmVersion'),
      planningWindow: TimeRange(
        startUtc: _utc(window['startUtcMicros'], 'startUtcMicros'),
        endUtc: _utc(window['endUtcMicros'], 'endUtcMicros'),
      ),
      blocks: [
        for (final raw in _list(body, 'blocks')) _blockFrom(_map(raw, 'block')),
      ],
      unscheduled: [
        for (final raw in _list(body, 'unscheduled'))
          _unscheduledFrom(_map(raw, 'unscheduled')),
      ],
      conflicts: [
        for (final raw in _list(body, 'conflicts'))
          _conflictFrom(_map(raw, 'conflict')),
      ],
      explanations: [
        for (final raw in _list(body, 'explanations'))
          PlanExplanation(
            code: _string(_map(raw, 'explanation'), 'code'),
            parameters: _objectMap(_map(raw, 'explanation')['parameters']),
          ),
      ],
      metrics: ProposalMetrics(
        isFullyFeasible: metrics['isFullyFeasible'] == true,
        scheduledMinutes: _int(metrics, 'scheduledMinutes'),
        unscheduledMinutes: _int(metrics, 'unscheduledMinutes'),
      ),
      adjustmentRequirement: _requirementFrom(body['adjustmentRequirement']),
      outcome: switch (body['outcome']) {
        final String name => SearchOutcomeKind.values.byName(name),
        _ => SearchOutcomeKind.solved,
      },
    );
  }

  PlannedBlock _blockFrom(Map<String, Object?> raw) => PlannedBlock(
    id: _string(raw, 'id'),
    taskId: _string(raw, 'taskId'),
    range: TimeRange(
      startUtc: _utc(raw['startUtcMicros'], 'startUtcMicros'),
      endUtc: _utc(raw['endUtcMicros'], 'endUtcMicros'),
    ),
    locked: raw['locked'] == true,
    explanationCode: raw['explanationCode'] as String?,
    continuedFromId: raw['continuedFromId'] as String?,
  );

  UnscheduledTask _unscheduledFrom(Map<String, Object?> raw) => UnscheduledTask(
    taskId: _string(raw, 'taskId'),
    shortageMinutes: _int(raw, 'shortageMinutes'),
    primaryReason: _reasonFrom(
      _map(raw['primaryReason'], 'primaryReason'),
    ),
    reasons: [
      for (final reason in _list(raw, 'reasons')) _reasonFrom(_map(reason, 'reason')),
    ],
  );

  PlanningConflict _conflictFrom(Map<String, Object?> raw) => PlanningConflict(
    code: ConflictCode.values.byName(_string(raw, 'code')),
    taskId: raw['taskId'] as String?,
    shortageMinutes: (raw['shortageMinutes'] as num?)?.toInt() ?? 0,
    invalidInputReason: switch (raw['invalidInputReason']) {
      final String name => InvalidInputReason.values.byName(name),
      _ => null,
    },
    blockingInput: raw['blockingInput'] as String?,
    relatedEntityIds: [
      for (final id in (raw['relatedEntityIds'] as List? ?? const []))
        id as String,
    ],
    details: _objectMap(raw['details']),
  );

  AdjustmentRequirement? _requirementFrom(Object? value) {
    if (value == null) return null;
    final raw = _map(value, 'adjustmentRequirement');
    return AdjustmentRequirement(
      targetBlockId: _string(raw, 'targetBlockId'),
      notBeforeUtc: _utc(raw['notBeforeUtcMicros'], 'notBeforeUtcMicros'),
      requiredMinutes: _int(raw, 'requiredMinutes'),
      originalStartUtc: _utc(
        raw['originalStartUtcMicros'],
        'originalStartUtcMicros',
      ),
    );
  }

  UnscheduledReason _reasonFrom(Map<String, Object?> raw) => UnscheduledReason(
    code: UnscheduledReasonCode.values.byName(_string(raw, 'code')),
    placementRemainingMinutes: _int(raw, 'placementRemainingMinutes'),
    constraintRequiredMinutes:
        (raw['constraintRequiredMinutes'] as num?)?.toInt(),
    constraintAvailableMinutes:
        (raw['constraintAvailableMinutes'] as num?)?.toInt(),
    constraintLabel: raw['constraintLabel'] as String?,
  );
  // ── 规范化与类型辅助 ──────────────────────────────────────────────────────

  Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonicalize(value[key])};
    }
    if (value is List) {
      return [for (final item in value) _canonicalize(item)];
    }
    return value;
  }

  Map<String, Object?> _objectMap(Object? value) => value is Map
      ? {for (final entry in value.entries) entry.key as String: entry.value}
      : const {};

  Map<String, Object?> _map(Object? value, String name) {
    if (value is Map) {
      return {for (final entry in value.entries) entry.key as String: entry.value};
    }
    throw FormatException('提案字段 $name 必须是对象。');
  }

  List<Object?> _list(Map<String, Object?> map, String name) {
    final value = map[name];
    if (value is List) return value;
    throw FormatException('提案字段 $name 必须是数组。');
  }

  String _string(Map<String, Object?> map, String name) {
    final value = map[name];
    if (value is String && value.isNotEmpty) return value;
    throw FormatException('提案字段 $name 必须是非空字符串。');
  }

  int _int(Map<String, Object?> map, String name) {
    final value = map[name];
    if (value is num) return value.toInt();
    throw FormatException('提案字段 $name 必须是整数。');
  }

  DateTime _utc(Object? value, String name) {
    if (value is num) {
      return DateTime.fromMicrosecondsSinceEpoch(value.toInt(), isUtc: true);
    }
    throw FormatException('时间字段 $name 必须是 UTC 微秒整数。');
  }
}

