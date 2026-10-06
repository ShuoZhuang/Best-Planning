import 'package:personal_planner/domain/models/academic_calendar.dart';

abstract interface class AcademicCalendarRepository {
  Future<List<AcademicTerm>> listTerms();

  Future<void> saveTerm(AcademicTerm term);

  Future<List<PeriodTemplate>> listTemplates();

  /// Replaces the template and all of its entries atomically.
  Future<void> saveTemplate(PeriodTemplate template);

  /// Makes exactly one existing template the default in a single transaction.
  Future<void> setDefaultTemplate(String templateId, DateTime updatedAtUtc);
}
