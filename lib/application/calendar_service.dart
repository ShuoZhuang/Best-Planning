import 'dart:collection';

import 'package:personal_planner/application/replanning_coordinator.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_event_deletion.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

enum EventEditScope { singleOccurrence, followingOccurrences, entireSeries }

final class EventDraft {
  const EventDraft({
    required this.title,
    required this.startAtUtc,
    required this.endAtUtc,
    // 必填：此前默认 'Asia/Shanghai'，而唯一的构造方 `EventEditorForm` 并没有传它，
    // 于是界面上保存的日程一律被标记为东八区——与需求 §13"以本机当前时区保存和展示"相悖，
    // 且只在别的时区表现为结果错误，不报错（R11）。
    required this.timeZoneId,
    this.recurrenceRuleId,
    this.exceptionOfId,
    this.locked = true,
    this.areaId,
    this.editScope = EventEditScope.singleOccurrence,
    this.recurrenceWeekdays = const {},
    this.recurrenceValidUntilLocalDate,
    this.recurrenceIntervalWeeks = 1,
  });

  final String title;
  final DateTime startAtUtc;
  final DateTime endAtUtc;
  final String timeZoneId;
  final String? recurrenceRuleId;
  final String? exceptionOfId;
  final bool locked;
  final String? areaId;
  final EventEditScope editScope;
  final Set<int> recurrenceWeekdays;
  final DateTime? recurrenceValidUntilLocalDate;
  final int recurrenceIntervalWeeks;
}

final class EventSaveResult {
  EventSaveResult.success(this.event) : fieldErrors = const <String, String>{};
  EventSaveResult.invalid(Map<String, String> errors)
    : event = null,
      fieldErrors = UnmodifiableMapView(errors);

  final CalendarEvent? event;
  final Map<String, String> fieldErrors;
  bool get isSuccess => event != null;
}

final class CalendarService {
  const CalendarService({
    required CalendarRepository repository,
    RecurringCalendarRepository? recurringRepository,
    CalendarEventDeletion? deletion,
    required Clock clock,
    required IdGenerator idGenerator,
    required TimeZoneDatabase zones,
    void Function(ScheduleInputChange change)? onScheduleInputChanged,
  }) : this._(
         repository,
         recurringRepository,
         deletion,
         clock,
         idGenerator,
         zones,
         onScheduleInputChanged,
       );

  const CalendarService._(
    this._repository,
    this._recurringRepository,
    this._deletion,
    this._clock,
    this._idGenerator,
    this._zones,
    this._onScheduleInputChanged,
  );

  final CalendarRepository _repository;
  final RecurringCalendarRepository? _recurringRepository;
  final CalendarEventDeletion? _deletion;
  final Clock _clock;
  final IdGenerator _idGenerator;
  final TimeZoneDatabase _zones;

  /// 固定日程的**创建／删除／改写**会改变排程输入——固定日程占用的时间是排程的硬约束，因此
  /// 每次成功写入各记一条 `replan:` 事件（FR-STAT-06 的"重排原因"）。
  ///
  /// 与 `TaskService.onScheduleInputChanged` **同一口径、同一装配点**：用回调而不是直接依赖统计
  /// 模块（日历服务不该知道统计存在），未装配时只是不留原因，不影响任何行为。原因码用人类可读
  /// 的话而不是枚举名，因为统计页把它**直接显示给用户**。
  ///
  /// **为什么现在才接**：这条路径此前登记为"未覆盖"（§13.0 W9 的 (a)）——任务侧的四类变化那时
  /// 已有发出者，而固定日程的增删改同样会改变排程，却因为写入方在日历服务里而漏掉。只覆盖一半
  /// 会让统计里的"重排原因"**看起来像一份完整分布**，实际却整整缺了日历这一类。
  ///
  /// **只记成功的写入**（与任务侧一致：改不动就没有重排）。唯一无法区分的情形是幂等删除——端口
  /// 的 `deleteEvent` 不返回"是否真的删掉了"，因此拿一个已过期的 id 来删也会记一条原因。这里选择
  /// 宁可多记一次意图，也不改动端口签名（它在 5 个测试替身里被实现，改签名会一次牵动 5 个文件）。
  final void Function(ScheduleInputChange change)? _onScheduleInputChanged;

  /// 改写整个系列（FR-CAL-02 的"整个系列"编辑一半）。所有各次一起换到新时间。
  ///
  /// 与 [replaceOccurrence] 同路：锚点与规则都在仓储侧读写（它才摸得到规则行），本服务只转发。
  Future<bool> replaceSeries({
    required String anchorId,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.replaceSeries(
      anchorId: anchorId,
      newStartUtc: newStartUtc,
      newEndUtc: newEndUtc,
      updatedAtUtc: _clock.nowUtc(),
    );
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程系列改写',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  Future<bool> replaceFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.replaceFollowingOccurrences(
      anchorId: anchorId,
      occurrenceStartUtc: occurrenceStartUtc,
      newStartUtc: newStartUtc,
      newEndUtc: newEndUtc,
      newRuleId: _idGenerator.next(),
      newEventId: _idGenerator.next(),
      updatedAtUtc: _clock.nowUtc(),
    );
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程本次及以后改写',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  Future<bool> deleteFollowingOccurrences({
    required String anchorId,
    required DateTime occurrenceStartUtc,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.deleteFollowingOccurrences(
      anchorId: anchorId,
      occurrenceStartUtc: occurrenceStartUtc,
      updatedAtUtc: _clock.nowUtc(),
    );
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程本次及以后删除',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  /// 改写重复日程里的某一次（FR-CAL-02 的"修改单次实例"）。
  ///
  /// 与 [deleteOccurrence] 同路：判定"是不是重复日程"与例外的时区都在仓储侧（它才摸得到规则
  /// 行）。未装配该端口时返回 `false`，而不是假装改掉了。
  Future<bool> replaceOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required DateTime newStartUtc,
    required DateTime newEndUtc,
    required String title,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.replaceOccurrence(
      anchorId: anchorId,
      occurrenceStartUtc: occurrenceStartUtc,
      newStartUtc: newStartUtc,
      newEndUtc: newEndUtc,
      title: title,
      exceptionId: _idGenerator.next(),
      updatedAtUtc: _clock.nowUtc(),
    );
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程单次改写',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  /// 只删除重复日程里的**某一次**（FR-CAL-02 的"修改单次实例"的删除一半）。
  ///
  /// 实现细节在仓储侧：写入一行**起止相同的零长度例外**（约定见 `DriftCalendarRepository`
  /// 的读取端与 §13.0 的 R4 行），锚点不带规则时退化为删除该行本身。
  /// 未装配重复日程端口时返回 `false`，而不是假装删掉了。
  Future<bool> deleteOccurrence({
    required String anchorId,
    required DateTime occurrenceStartUtc,
    required String title,
  }) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.deleteOccurrence(
      anchorId: anchorId,
      occurrenceStartUtc: occurrenceStartUtc,
      title: title,
      exceptionId: _idGenerator.next(),
      updatedAtUtc: _clock.nowUtc(),
    );
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程单次删除',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  /// 删除一条固定日程（FR-CAL-01）。未装配删除端口时返回 false，而不是假装删掉了。
  ///
  /// 返回 `bool`：界面据此显示"已删除／未装配"。**幂等**语义让"记录已不在"也算成功——调用方
  /// 拿到的 id 可能来自一次已过期的视图。
  Future<bool> deleteEvent(String eventId) async {
    final deletion = _deletion;
    if (deletion == null) return false;
    await deletion.deleteEvent(eventId);
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程删除',
        kind: DomainChangeKind.fixedEventChanged,
      ),
    );
    return true;
  }

  Future<EventSaveResult> save(EventDraft draft) async {
    final errors = <String, String>{};
    if (draft.title.trim().isEmpty) errors['title'] = '请输入日程标题';
    if (!draft.startAtUtc.isUtc || !draft.endAtUtc.isUtc) {
      errors['time'] = '日程时间必须转换为 UTC';
    } else if (!draft.endAtUtc.isAfter(draft.startAtUtc)) {
      errors['time'] = '结束时间必须晚于开始时间';
    }
    if (draft.timeZoneId.trim().isEmpty) errors['timeZoneId'] = '请选择时区';
    if (draft.recurrenceWeekdays.any((day) => day < 1 || day > 7)) {
      errors['recurrence'] = '重复星期无效';
    }
    if (draft.recurrenceWeekdays.isNotEmpty && _recurringRepository == null) {
      errors['recurrence'] = '当前日历存储不支持重复日程';
    }
    if (draft.recurrenceWeekdays.isNotEmpty &&
        draft.startAtUtc.isUtc &&
        draft.timeZoneId.trim().isNotEmpty) {
      final localStart = _zones.toLocal(draft.startAtUtc, draft.timeZoneId);
      final firstLocalDate = DateTime(
        localStart.year,
        localStart.month,
        localStart.day,
      );
      final validUntil = draft.recurrenceValidUntilLocalDate;
      if (draft.recurrenceIntervalWeeks < 1 ||
          draft.recurrenceIntervalWeeks > 52) {
        errors['recurrence'] = '重复间隔必须在 1 到 52 周之间';
      } else if (validUntil != null &&
          _dateOnly(validUntil).isBefore(firstLocalDate)) {
        errors['recurrence'] = '重复结束日期不能早于开始日期';
      }
    }
    if (errors.isNotEmpty) return EventSaveResult.invalid(errors);

    final now = _clock.nowUtc();
    final recurring = draft.recurrenceWeekdays.isNotEmpty;
    final ruleId = recurring ? _idGenerator.next() : null;
    final event = CalendarEvent(
      id: _idGenerator.next(),
      title: draft.title,
      startAtUtc: draft.startAtUtc,
      endAtUtc: draft.endAtUtc,
      timeZoneId: draft.timeZoneId,
      recurrenceRuleId: ruleId ?? draft.recurrenceRuleId,
      exceptionOfId: draft.exceptionOfId,
      locked: draft.locked,
      areaId: draft.areaId,
      updatedAtUtc: now,
    );
    if (recurring) {
      final localStart = _zones.toLocal(draft.startAtUtc, draft.timeZoneId);
      final rule = RecurrenceRule(
        id: ruleId!,
        weekdays: draft.recurrenceWeekdays,
        localStartMinute: localStart.hour * 60 + localStart.minute,
        durationMinutes: draft.endAtUtc.difference(draft.startAtUtc).inMinutes,
        intervalWeeks: draft.recurrenceIntervalWeeks,
        validFromLocalDate: DateTime(
          localStart.year,
          localStart.month,
          localStart.day,
        ),
        validUntilLocalDate: draft.recurrenceValidUntilLocalDate == null
            ? null
            : _dateOnly(draft.recurrenceValidUntilLocalDate!),
        timeZoneId: draft.timeZoneId,
      );
      await _recurringRepository!.saveRecurring(event, rule);
    } else {
      await _repository.save(event);
    }
    _onScheduleInputChanged?.call(
      const ScheduleInputChange(
        label: '固定日程创建',
        kind: DomainChangeKind.fixedEventCreated,
      ),
    );
    return EventSaveResult.success(event);
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);
