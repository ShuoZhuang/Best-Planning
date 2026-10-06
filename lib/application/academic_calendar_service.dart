import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/academic_calendar.dart';
import 'package:personal_planner/domain/repositories/academic_calendar_repository.dart';

final class AcademicCalendarService {
  const AcademicCalendarService({
    required this.repository,
    required this.clock,
    required this.idGenerator,
  });

  final AcademicCalendarRepository repository;
  final Clock clock;
  final IdGenerator idGenerator;

  Future<List<AcademicTerm>> listTerms() => repository.listTerms();

  Future<List<PeriodTemplate>> listTemplates() => repository.listTemplates();

  Future<AcademicTerm> saveTerm({
    AcademicTerm? existing,
    required String name,
    required DateTime firstWeekMonday,
    required int totalWeeks,
    required String timeZoneId,
  }) async {
    final now = clock.nowUtc();
    final term = AcademicTerm(
      id: existing?.id ?? idGenerator.next(),
      name: name,
      firstWeekMonday: firstWeekMonday,
      totalWeeks: totalWeeks,
      timeZoneId: timeZoneId,
      createdAtUtc: existing?.createdAtUtc ?? now,
      updatedAtUtc: now,
    );
    await repository.saveTerm(term);
    return term;
  }

  Future<PeriodTemplate> saveTemplate({
    PeriodTemplate? existing,
    required String name,
    required List<PeriodEntry> entries,
    bool isDefault = false,
  }) async {
    final now = clock.nowUtc();
    final template = PeriodTemplate(
      id: existing?.id ?? idGenerator.next(),
      name: name,
      isDefault: isDefault,
      entries: entries,
      createdAtUtc: existing?.createdAtUtc ?? now,
      updatedAtUtc: now,
    );
    await repository.saveTemplate(template);
    if (isDefault) {
      await repository.setDefaultTemplate(template.id, now);
    }
    return template;
  }

  Future<void> setDefaultTemplate(String templateId) =>
      repository.setDefaultTemplate(templateId, clock.nowUtc());
}
