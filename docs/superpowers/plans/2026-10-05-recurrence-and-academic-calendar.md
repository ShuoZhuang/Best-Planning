# Recurrence and Academic Calendar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add interval-week recurrence, odd/even-week behavior, academic-term week conversion, editable period templates, and complete single/future/series editing before timetable OCR is introduced.

**Architecture:** Extend the existing recurrence rule with `intervalWeeks` and keep local calendar dates as recurrence anchors. Academic terms and period templates are separate domain objects with Drift repositories and settings UI. Existing exception events continue to represent one-off changes; “this and future” splits a series transactionally at the selected occurrence.

**Tech Stack:** Flutter/Dart, Drift/SQLite schema v5, existing `TimeZoneDatabase` and `RecurrenceExpander`, GoRouter, unit/widget/migration tests.

**Spec:** `docs/superpowers/specs/2026-10-05-task-area-and-timetable-import-design.md`

## Global Constraints

- Requires completion of `2026-10-05-task-classification-and-start-constraint.md` and schema v4.
- Recurrence is calculated from local dates, never by dividing UTC duration into days or weeks.
- `intervalWeeks` is 1–52; weekly is 1, odd/even shortcuts use 2 with different valid-from anchors.
- Every period has a unique positive number and `0 <= startMinute < endMinute <= 1440`.
- Academic week 1 starts on the configured local Monday.
- Existing weekly rules migrate with `intervalWeeks = 1` and identical occurrences.
- Do not include OCR or image parsing in this phase.

## Review Focus

- A fortnightly rule spanning a DST transition must stay at the same local clock time.
- An even-week shortcut must anchor at week 2 rather than merely label a week-1 series “even”.
- Reference-date ↔ first-week-Monday conversion must work for a reference date in any weekday.
- Splitting “this and future” must neither duplicate nor lose the selected occurrence.
- Period templates must reject duplicate period numbers and overlapping/inverted times without partial writes.

---

### Task 1: Add recurrence interval, terms, and period-template schema

**Files:**
- Modify: `lib/data/database/tables/planner_tables.dart`
- Modify: `lib/data/database/app_database.dart`
- Regenerate: `lib/data/database/app_database.g.dart`
- Regenerate: `lib/data/database/app_database.steps.dart`
- Create: `drift_schemas/app_database/schema_v5.json`
- Regenerate: `test/drift/app_database/generated/schema.dart`
- Create: `test/drift/app_database/generated/schema_v5.dart`
- Modify: `test/drift/app_database/schema_migration_test.dart`

**Interfaces:**
- Produces: `recurrence_rules.interval_weeks INTEGER NOT NULL DEFAULT 1`
- Produces tables: `academic_terms`, `period_templates`, `period_template_entries`
- Migration: schema v4 → v5

- [ ] **Step 1: Write failing migration tests**

Assert every v1–v4 schema migrates to v5; existing rules have `intervalWeeks == 1`; task fields from v4 survive; a term and a multi-row period template enforce foreign keys and composite uniqueness.

- [ ] **Step 2: Run migration tests and verify failure**

Run: `flutter test test/drift/app_database/schema_migration_test.dart`

Expected: FAIL because v5 does not exist.

- [ ] **Step 3: Implement v5 tables and upgrade**

Add `AcademicTerms`, `PeriodTemplates`, and `PeriodTemplateEntries` exactly as the spec defines. Add `intervalWeeks` with default 1. Register all tables and implement `_upgradeToV5` without rewriting existing recurrence rows.

- [ ] **Step 4: Regenerate Drift and schema fixtures**

Run:

```powershell
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev make-migrations
dart run drift_dev schema generate drift_schemas/app_database/ test/drift/app_database/generated/ --data-classes --companions
```

Expected: v5 generated files compile.

- [ ] **Step 5: Run migration tests and verify pass**

Run: `flutter test test/drift/app_database/schema_migration_test.dart`

Expected: PASS for all version pairs.

- [ ] **Step 6: Commit**

```powershell
git add lib/data/database drift_schemas/app_database test/drift/app_database
git commit -m "feat: add academic calendar schema"
```

### Task 2: Implement interval-week recurrence expansion

**Files:**
- Modify: `lib/domain/models/calendar_event.dart`
- Modify: `lib/domain/services/recurrence_expander.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/domain/recurrence_expander_test.dart`
- Modify: `test/data/recurrence_exception_test.dart`

**Interfaces:**
- Changes: `RecurrenceRule` adds named parameter `int intervalWeeks = 1`; its existing named parameters remain unchanged
- Week anchor: Monday of `validFromLocalDate`’s local week
- Inclusion: `weekOffset % intervalWeeks == 0`

- [ ] **Step 1: Write failing recurrence tests**

Add tests for every two weeks, odd weeks, even weeks, inclusive valid-until boundaries, multiple weekdays, exceptions on skipped weeks, and America/New_York DST while preserving local clock time. Reject interval 0 and 53.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/domain/recurrence_expander_test.dart test/data/recurrence_exception_test.dart`

Expected: FAIL because rules expand every matching weekday.

- [ ] **Step 3: Implement local-week interval calculation and persistence**

Normalize `validFromLocalDate` and candidate dates to local Mondays, compute integer day difference divided by seven, and require a non-negative multiple of `intervalWeeks`. Map the new Drift field in every read/write path.

- [ ] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS, including DST tests.

- [ ] **Step 5: Commit**

```powershell
git add lib/domain/models/calendar_event.dart lib/domain/services/recurrence_expander.dart lib/data/repositories/drift_calendar_repository.dart test/domain/recurrence_expander_test.dart test/data/recurrence_exception_test.dart
git commit -m "feat: support interval week recurrence"
```

### Task 3: Add academic-term and period-template domain services

**Files:**
- Create: `lib/domain/models/academic_calendar.dart`
- Create: `lib/domain/repositories/academic_calendar_repository.dart`
- Create: `lib/data/repositories/drift_academic_calendar_repository.dart`
- Create: `lib/application/academic_calendar_service.dart`
- Create: `test/domain/academic_calendar_test.dart`
- Create: `test/data/academic_calendar_repository_test.dart`
- Create: `test/application/academic_calendar_service_test.dart`

**Interfaces:**
- Produces: `AcademicTerm({required String id, required String name, required DateTime firstWeekMonday, required int totalWeeks, required String timeZoneId, required DateTime createdAtUtc, required DateTime updatedAtUtc})`
- Produces: `PeriodTemplate({required String id, required String name, required bool isDefault, required List<PeriodEntry> entries, required DateTime createdAtUtc, required DateTime updatedAtUtc})`
- Produces: `AcademicWeekCalculator.firstWeekMonday(referenceDate:, weekNumber:)`
- Produces: `AcademicWeekCalculator.weekNumber(firstWeekMonday:, date:)`
- Produces: `AcademicCalendarService.saveTerm`, `saveTemplate`, `setDefaultTemplate`

- [ ] **Step 1: Write failing domain and repository tests**

Use the confirmed example `2026-10-05 = week 5` and assert first-week Monday is `2026-09-07`; reverse conversion returns 5. Test Sundays, dates before week 1, leap-year dates, total weeks 1–60, invalid names, duplicate period numbers, inverted times, and atomic template replacement.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/domain/academic_calendar_test.dart test/data/academic_calendar_repository_test.dart test/application/academic_calendar_service_test.dart`

Expected: FAIL because the academic-calendar module does not exist.

- [ ] **Step 3: Implement models, calculator, repository, and service**

Store dates as `YYYY-MM-DD` local-date strings. `firstWeekMonday` subtracts `(weekNumber - 1) * 7` days from the Monday of the reference date’s week. Save a template and its entries in one transaction; setting a default clears the prior default in the same transaction.

- [ ] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/domain/models/academic_calendar.dart lib/domain/repositories/academic_calendar_repository.dart lib/data/repositories/drift_academic_calendar_repository.dart lib/application/academic_calendar_service.dart test/domain/academic_calendar_test.dart test/data/academic_calendar_repository_test.dart test/application/academic_calendar_service_test.dart
git commit -m "feat: add academic terms and period templates"
```

### Task 4: Extend calendar service drafts with complete recurrence bounds

**Files:**
- Modify: `lib/application/calendar_service.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/application/calendar_replan_events_test.dart`
- Modify: `test/features/calendar/event_editor_test.dart`
- Modify: `test/data/calendar_event_deletion_test.dart`

**Interfaces:**
- Changes: `EventDraft` adds `recurrenceValidUntilLocalDate`, `recurrenceIntervalWeeks`
- Produces validation errors under `recurrence`
- Persists `validUntilLocalDate` and `intervalWeeks`

- [ ] **Step 1: Write failing service tests**

Assert weekly defaults to interval 1; interval 2 and valid-until persist; end before start is rejected; interval outside 1–52 is rejected; non-recurring events ignore recurrence-only fields; successful saves emit one replan reason.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/application/calendar_replan_events_test.dart test/features/calendar/event_editor_test.dart test/data/calendar_event_deletion_test.dart`

Expected: FAIL because the draft cannot carry bounds or intervals.

- [ ] **Step 3: Implement draft validation and rule construction**

Construct `RecurrenceRule` with the user-selected local start/end dates and interval. Preserve existing behavior for one-off events and existing series editing.

- [ ] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/application/calendar_service.dart lib/data/repositories/drift_calendar_repository.dart test/application/calendar_replan_events_test.dart test/features/calendar/event_editor_test.dart test/data/calendar_event_deletion_test.dart
git commit -m "feat: add bounded interval recurrence drafts"
```

### Task 5: Add “this and future” series operations

**Files:**
- Modify: `lib/domain/repositories/calendar_event_deletion.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `lib/application/calendar_service.dart`
- Modify: `lib/features/calendar/day_view/day_view_page.dart`
- Modify: `test/data/calendar_event_deletion_test.dart`
- Modify: `test/features/calendar/day_view_test.dart`

**Interfaces:**
- Changes: `EventEditScope` adds `followingOccurrences`
- Produces: `CalendarEventDeletion.replaceFollowingOccurrences({required String anchorId, required DateTime occurrenceStartUtc, required DateTime newStartUtc, required DateTime newEndUtc, required String newRuleId, required String newEventId, required DateTime updatedAtUtc})`
- Produces: `CalendarEventDeletion.deleteFollowingOccurrences({required String anchorId, required DateTime occurrenceStartUtc, required DateTime updatedAtUtc})`

- [ ] **Step 1: Write failing split-series tests**

For an occurrence on 2026-10-12, assert replace-following sets the old rule’s end to 2026-10-11 and creates a new anchor/rule starting 2026-10-12. Assert delete-following only truncates the old rule. Assert the selected occurrence appears exactly once and earlier exceptions remain attached only to the old anchor.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/data/calendar_event_deletion_test.dart test/features/calendar/day_view_test.dart`

Expected: FAIL because only single and entire-series operations exist.

- [ ] **Step 3: Implement transactional series split**

Add the two port methods and corresponding `CalendarService` methods. In the Drift repository, load the anchor and rule, validate the split local date, truncate the old rule to the previous local day, and optionally insert the new rule/anchor in one transaction. The UI action sheet exposes 仅本次、本次及以后、整个系列.

- [ ] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add lib/domain/repositories/calendar_event_deletion.dart lib/data/repositories/drift_calendar_repository.dart lib/application/calendar_service.dart lib/features/calendar/day_view/day_view_page.dart test/data/calendar_event_deletion_test.dart test/features/calendar/day_view_test.dart
git commit -m "feat: edit recurring events from an occurrence forward"
```

### Task 6: Build recurrence and academic-calendar settings UI

**Files:**
- Modify: `lib/features/calendar/event_editor/event_editor_form.dart`
- Create: `lib/features/settings/academic_calendar/academic_calendar_page.dart`
- Create: `lib/features/settings/academic_calendar/period_template_editor.dart`
- Modify: `lib/features/settings/settings_hub_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/app/planner_app.dart`
- Modify: `lib/main.dart`
- Modify: `test/features/calendar/event_editor_test.dart`
- Create: `test/features/settings/academic_calendar_page_test.dart`
- Modify: `test/app/settings_hub_test.dart`

**Interfaces:**
- Consumes: `AcademicCalendarService`
- Produces route: `/settings/academic-calendar`
- Produces setting key: `settings-academic-calendar`
- Recurrence shortcuts: 每周, 每两周, 单周, 双周, 自定义

- [ ] **Step 1: Write failing widget and route tests**

Assert the event editor can set start/end dates and interval; odd/even shortcuts produce the correct anchor; the settings hub opens the academic-calendar page; editing current week recalculates first-week Monday and editing first-week Monday recalculates the current week; each period row is editable and validation is inline.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/features/calendar/event_editor_test.dart test/features/settings/academic_calendar_page_test.dart test/app/settings_hub_test.dart`

Expected: FAIL because these controls and route do not exist.

- [ ] **Step 3: Implement responsive forms**

Use visible labels, 12px row gaps, 24px section gaps, and 44px minimum controls. The term section shows the bidirectional calculation with the reference date; the period editor supports batch generation then per-row correction. Persist only after all rows validate.

- [ ] **Step 4: Run phase verification**

Run:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter test integration_test -d windows
```

Expected: all checks pass and existing weekly events expand unchanged.

- [ ] **Step 5: Commit**

```powershell
git add lib/features/calendar/event_editor lib/features/settings/academic_calendar lib/features/settings/settings_hub_page.dart lib/app/router.dart lib/app/planner_app.dart lib/main.dart test/features/calendar test/features/settings test/app/settings_hub_test.dart
git commit -m "feat: add recurrence and academic calendar UI"
```
