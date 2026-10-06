import 'package:drift/drift.dart';

/// Timestamp columns follow FR-DATA-08: every core record carries a creation
/// and a modification time. Existing databases are upgraded by adding these
/// columns with the sentinel default [unsetTimestamp] and then backfilling the
/// migration instant into every historical row (see `AppDatabase.migration`).
///
/// The sentinel exists because SQLite cannot add a `NOT NULL` column without a
/// default. Repositories always write a real instant, so the sentinel is only
/// observable for a row that was never written through a repository.
const int unsetTimestamp = 0;

class Areas extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get color => integer()();
  IntColumn get sortOrder => integer()();

  /// Marks an area as belonging to life rather than work, which the life-quota
  /// soft constraint and the calendar life category both read.
  BoolColumn get isLife => boolean().withDefault(const Constant(false))();

  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Projects extends Table {
  TextColumn get id => text()();
  TextColumn get areaId => text().references(Areas, #id)();
  TextColumn get name => text()();
  IntColumn get archivedAtUtc => integer().nullable()();
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Tasks extends Table {
  TextColumn get id => text()();
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get areaId => text().nullable().references(Areas, #id)();
  TextColumn get title => text()();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get priority => text()();
  IntColumn get estimatedMinutes => integer()();
  IntColumn get remainingMinutes => integer()();
  IntColumn get dueAtUtc => integer().nullable()();
  IntColumn get availableFromUtc => integer().nullable()();
  TextColumn get energyLevel => text()();
  TextColumn get splitMode => text()();
  IntColumn get minChunkMinutes => integer()();
  IntColumn get maxChunkMinutes => integer()();

  /// Optional preferred local-time window, expressed as minutes from local
  /// midnight on the task's day. Null means the task has no preference.
  IntColumn get preferredStartMinute => integer().nullable()();
  IntColumn get preferredEndMinute => integer().nullable()();

  TextColumn get status => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Custom tags (FR-TASK-01, FR-STAT-02). A dedicated table plus a join table is
/// used instead of a delimited text column so that filtering and statistics can
/// match tags exactly rather than by substring.
class Tags extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Association between tasks and tags. The composite key is the row identity;
/// a link is created or deleted rather than edited, so it records a creation
/// time but no modification time.
class TaskTags extends Table {
  TextColumn get taskId => text().references(Tasks, #id)();
  TextColumn get tagId => text().references(Tags, #id)();
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {taskId, tagId};
}

class RecurrenceRules extends Table {
  TextColumn get id => text()();
  IntColumn get weekdaysMask => integer()();
  IntColumn get localStartMinute => integer()();
  IntColumn get durationMinutes => integer()();
  IntColumn get intervalWeeks => integer().customConstraint(
    'NOT NULL DEFAULT 1 CHECK (interval_weeks BETWEEN 1 AND 52)',
  )();
  TextColumn get validFromLocalDate => text()();
  TextColumn get validUntilLocalDate => text().nullable()();
  TextColumn get timeZoneId => text()();
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// A locally anchored teaching term. The first week always starts on the
/// configured local Monday; the date is stored as YYYY-MM-DD rather than an
/// instant so daylight-saving changes cannot shift academic week boundaries.
class AcademicTerms extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get firstWeekMondayLocalDate => text()();
  IntColumn get totalWeeks => integer().customConstraint(
    'NOT NULL CHECK (total_weeks BETWEEN 1 AND 60)',
  )();
  TextColumn get timeZoneId => text()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Named collections of school-period clock times. Users can keep more than
/// one template (for example, separate campuses), while [isDefault] selects
/// the one prefilled in timetable import.
class PeriodTemplates extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  BoolColumn get isDefault => boolean().withDefault(const Constant(false))();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// One editable period within a template. The composite primary key prevents
/// duplicate period numbers, and the database-level checks protect imports
/// even if a future caller bypasses the application service validation.
class PeriodTemplateEntries extends Table {
  TextColumn get templateId =>
      text().references(PeriodTemplates, #id, onDelete: KeyAction.cascade)();
  IntColumn get periodNumber => integer()();
  IntColumn get startMinute => integer()();
  IntColumn get endMinute => integer()();

  @override
  Set<Column<Object>> get primaryKey => {templateId, periodNumber};

  @override
  List<String> get customConstraints => [
    'CHECK (period_number > 0)',
    'CHECK (start_minute >= 0 AND start_minute < end_minute AND end_minute <= 1440)',
  ];
}

class TimetableImportBatches extends Table {
  TextColumn get id => text()();
  TextColumn get termId => text().references(AcademicTerms, #id)();
  TextColumn get sourceImageHash => text()();
  TextColumn get sourceFileName => text()();
  TextColumn get status => text()();
  IntColumn get createdEventCount => integer()();
  IntColumn get createdAtUtc => integer()();
  IntColumn get updatedAtUtc => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (status IN ('draft', 'committed', 'rolledBack'))",
    'CHECK (created_event_count >= 0)',
  ];
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
  TextColumn get projectId => text().nullable().references(Projects, #id)();
  TextColumn get location => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get sourceKind => text().withDefault(const Constant('manual'))();
  TextColumn get importBatchId =>
      text().nullable().references(TimetableImportBatches, #id)();
  TextColumn get logicalCourseId => text().nullable()();
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
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
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get jsonValue => text()();
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
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
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
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
  IntColumn get createdAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  IntColumn get updatedAtUtc =>
      integer().withDefault(const Constant(unsetTimestamp))();
  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// 剩余时长修正记录（FR-TASK-05）。
///
/// 任务表只保存当前剩余值，历史必须另有出处；而统计要看的正是"用户每次修正多少、
/// 往哪个方向修正"（§8 的预估偏差口径），因此保留**修正前后两个值**，而不是只存
/// 一个结果。
///
/// 单独建表而不是塞进 `change_log`：后者的用途是"为撤销、诊断和未来同步保留最小
/// 变更历史"，只有 `operation` 一个文本列可放内容，把两个整数编码进字符串会让统计
/// 必须先解析文本再计算——正是本项目在别处（按领域名猜生活标记）刚移除的那类做法。
///
/// 记录一旦写入不再修改，因此按 FR-DATA-08 只记创建时刻 `corrected_at_utc`，
/// 与 `plan_versions`、`preference_evidence`、`change_log` 的处理一致。
class TaskCorrections extends Table {
  TextColumn get id => text()();
  TextColumn get taskId => text().references(Tasks, #id)();
  IntColumn get previousMinutes => integer()();
  IntColumn get correctedMinutes => integer()();
  IntColumn get correctedAtUtc => integer()();
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
