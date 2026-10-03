import 'dart:collection';

import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/calendar_event.dart';
import 'package:personal_planner/domain/repositories/calendar_repository.dart';

enum EventEditScope { singleOccurrence, entireSeries }

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
    required Clock clock,
    required IdGenerator idGenerator,
  }) : this._(repository, clock, idGenerator);

  const CalendarService._(this._repository, this._clock, this._idGenerator);

  final CalendarRepository _repository;
  final Clock _clock;
  final IdGenerator _idGenerator;

  Future<EventSaveResult> save(EventDraft draft) async {
    final errors = <String, String>{};
    if (draft.title.trim().isEmpty) errors['title'] = '请输入日程标题';
    if (!draft.startAtUtc.isUtc || !draft.endAtUtc.isUtc) {
      errors['time'] = '日程时间必须转换为 UTC';
    } else if (!draft.endAtUtc.isAfter(draft.startAtUtc)) {
      errors['time'] = '结束时间必须晚于开始时间';
    }
    if (draft.timeZoneId.trim().isEmpty) errors['timeZoneId'] = '请选择时区';
    if (errors.isNotEmpty) return EventSaveResult.invalid(errors);

    final event = CalendarEvent(
      id: _idGenerator.next(),
      title: draft.title,
      startAtUtc: draft.startAtUtc,
      endAtUtc: draft.endAtUtc,
      timeZoneId: draft.timeZoneId,
      recurrenceRuleId: draft.recurrenceRuleId,
      exceptionOfId: draft.exceptionOfId,
      locked: draft.locked,
      areaId: draft.areaId,
      updatedAtUtc: _clock.nowUtc(),
    );
    await _repository.save(event);
    return EventSaveResult.success(event);
  }
}
