import 'package:drift/drift.dart';

class Areas extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  IntColumn get sortOrder => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get areaId => text().references(Areas, #id)();
  TextColumn get name => text()();
  IntColumn get archivedAtUtc => integer().nullable()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get priority => text()();
  IntColumn get estimatedMinutes => integer()();
  IntColumn get remainingMinutes => integer()();
  IntColumn get dueAtUtc => integer().nullable()();
  TextColumn get energyLevel => text()();
  TextColumn get splitMode => text()();
  IntColumn get minChunkMinutes => integer()();
  IntColumn get maxChunkMinutes => integer()();
  TextColumn get status => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class RecurrenceRules extends Table {
  TextColumn get id => text()();
  IntColumn get weekdaysMask => integer()();
  IntColumn get localStartMinute => integer()();
  IntColumn get durationMinutes => integer()();
  TextColumn get validFromLocalDate => text()();
  TextColumn get validUntilLocalDate => text().nullable()();
  TextColumn get timeZoneId => text()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class CalendarEvents extends Table {
  TextColumn get id => text()();
  TextColumn get title => text()();
  IntColumn get startAtUtc => integer()();
  IntColumn get endAtUtc => integer()();
  TextColumn get timeZoneId => text()();
  TextColumn get recurrenceRuleId =>
      text().nullable().references(RecurrenceRules, #id)();
  TextColumn get exceptionOfId =>
      text().nullable().references(CalendarEvents, #id)();
  BoolColumn get locked => boolean().withDefault(const Constant(true))();
  TextColumn get areaId => text().nullable().references(Areas, #id)();
  IntColumn get updatedAtUtc => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class EnergyWindows extends Table {
  TextColumn get id => text()();
  TextColumn get dayKind => text()();
  IntColumn get startMinute => integer()();
  IntColumn get endMinute => integer()();
  TextColumn get energyLevel => text()();
  TextColumn get source => text()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get jsonValue => text()();
  IntColumn get updatedAtUtc => integer()();
  @override
  Set<Column<Object>> get primaryKey => {key};
}

class PlanVersions extends Table {
  TextColumn get id => text()();
  IntColumn get createdAtUtc => integer()();
  TextColumn get inputHash => text()();
  TextColumn get algorithmVersion => text()();
  TextColumn get status => text()();
  TextColumn get summaryJson => text()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ScheduleBlocks extends Table {
  TextColumn get id => text()();
  TextColumn get planVersionId => text().references(PlanVersions, #id)();
  TextColumn get taskId => text().references(Tasks, #id)();
  IntColumn get startAtUtc => integer()();
  IntColumn get endAtUtc => integer()();
  BoolColumn get locked => boolean().withDefault(const Constant(false))();
  TextColumn get explanationCode => text()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class TimeEntries extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text().references(Tasks, #id)();
  IntColumn get startedAtUtc => integer()();
  IntColumn get endedAtUtc => integer().nullable()();
  IntColumn get pausedMinutes => integer().withDefault(const Constant(0))();
  TextColumn get source => text()();
  TextColumn get recoveryState => text()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PreferenceEvidence extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get subjectKey => text()();
  IntColumn get observedAtUtc => integer()();
  RealColumn get numericValue => real().nullable()();
  BoolColumn get specialDay => boolean().withDefault(const Constant(false))();
  TextColumn get metadataJson => text()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class PreferenceRules extends Table {
  TextColumn get id => text()();
  TextColumn get kind => text()();
  TextColumn get subjectKey => text()();
  TextColumn get valueJson => text()();
  RealColumn get confidence => real()();
  TextColumn get status => text()();
  TextColumn get source => text()();
  IntColumn get updatedAtUtc => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class ChangeLog extends Table {
  TextColumn get id => text()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get operation => text()();
  IntColumn get changedAtUtc => integer()();
  IntColumn get revision => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}
