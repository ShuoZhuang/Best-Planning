# Local Timetable Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import a school timetable image through the approved five-step wizard, recognize it locally on Windows, require user correction and preview, then commit locked recurring course events as an undoable batch.

**Architecture:** A Dart `TimetableOcrEngine` port isolates a Windows C++/WinRT method-channel adapter. OCR output is converted into an editable `TimetableDraft`; preview expands concrete dates and detects conflicts/duplicates without writing. A Drift transaction commits recurrence rules, calendar anchors, and one import batch, while rollback protects events changed after import.

**Tech Stack:** Flutter/Dart, Windows C++/WinRT `Windows.Media.Ocr`, Flutter MethodChannel, Drift/SQLite schema v6, `file_selector`, existing recurrence/time-zone/scheduling services.

**Spec:** `docs/superpowers/specs/2026-10-05-task-area-and-timetable-import-design.md`

## Global Constraints

- Requires both earlier plans and schema v5.
- OCR and parsing run locally; no network dependency or cloud fallback.
- Windows OCR provides recognized text, line/word bounds and text angle, but no confidence score. “需要检查” comes from parser ambiguity and missing/inconsistent rules.
- Raw timetable images are not stored in the database, export, backup, or diagnostic logs.
- Recognition only creates an in-memory draft; database writes begin after final user confirmation.
- Imported courses are locked fixed events and use the direct area, defaulting to 学业.
- Batch commit and rollback are atomic and emit one scheduling-input change each.
- Official Windows API references: [OcrEngine](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine), [RecognizeAsync](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrengine.recognizeasync), [OcrWord.BoundingRect](https://learn.microsoft.com/en-us/uwp/api/windows.media.ocr.ocrword.boundingrect).

## Review Focus

- Missing Simplified Chinese OCR capability must offer manual entry without losing the selected image or wizard state.
- Crop/rotation coordinates must stay aligned with returned word bounds and weekday/period geometry.
- Non-contiguous week ranges and odd/even spans must create correct independent series without duplicate occurrences.
- Re-importing the same image for the same term must default to skip, not silently duplicate courses.
- Batch rollback must not silently delete an imported event that the user later edited or gave exceptions.

---

### Task 1: Add import-batch and course-event persistence

**Files:**
- Modify: `lib/data/database/tables/planner_tables.dart`
- Modify: `lib/data/database/app_database.dart`
- Regenerate: `lib/data/database/app_database.g.dart`
- Regenerate: `lib/data/database/app_database.steps.dart`
- Create: `drift_schemas/app_database/schema_v6.json`
- Regenerate: `test/drift/app_database/generated/schema.dart`
- Create: `test/drift/app_database/generated/schema_v6.dart`
- Modify: `test/drift/app_database/schema_migration_test.dart`
- Modify: `lib/domain/models/calendar_event.dart`
- Modify: `lib/data/repositories/drift_calendar_repository.dart`
- Modify: `test/data/repository_round_trip_test.dart`

**Interfaces:**
- Produces table: `timetable_import_batches`
- Extends `calendar_events`: `projectId`, `location`, `notes`, `sourceKind`, `importBatchId`, `logicalCourseId`
- Produces enum: `CalendarEventSourceKind.manual`, `timetableImport`
- Migration: schema v5 → v6

- [ ] **Step 1: Write failing migration and round-trip tests**

Assert old events migrate with empty location/notes, `sourceKind == manual`, and null import metadata. Assert a timetable event round-trips all new fields. Assert an import batch references an existing academic term and rejects a missing one.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/drift/app_database/schema_migration_test.dart test/data/repository_round_trip_test.dart`

Expected: FAIL because v6 fields and table do not exist.

- [ ] **Step 3: Implement schema v6 and calendar mapping**

Create `TimetableImportBatches` with the spec fields and timestamps. Create the batch table before adding `calendar_events.importBatchId`; add safe defaults for new non-null event columns. Extend `CalendarEvent`, `CalendarOccurrence`, copy methods, and Drift repository mapping.

- [ ] **Step 4: Regenerate Drift and fixtures**

Run:

```powershell
dart run build_runner build --delete-conflicting-outputs
dart run drift_dev make-migrations
dart run drift_dev schema generate drift_schemas/app_database/ test/drift/app_database/generated/ --data-classes --companions
```

Expected: v6 generated code compiles.

- [ ] **Step 5: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS for every migration path and round trip.

- [ ] **Step 6: Commit**

```powershell
git add lib/data/database lib/domain/models/calendar_event.dart lib/data/repositories/drift_calendar_repository.dart drift_schemas/app_database test/drift/app_database test/data/repository_round_trip_test.dart
git commit -m "feat: add timetable import persistence"
```

### Task 2: Implement the local Windows OCR adapter

**Files:**
- Create: `lib/domain/ocr/timetable_ocr.dart`
- Create: `lib/platform/ocr/windows_timetable_ocr.dart`
- Create: `windows/runner/timetable_ocr_channel.h`
- Create: `windows/runner/timetable_ocr_channel.cpp`
- Modify: `windows/runner/flutter_window.cpp`
- Modify: `windows/runner/CMakeLists.txt`
- Create: `test/platform/windows_timetable_ocr_test.dart`
- Create: `test/domain/timetable_ocr_contract_test.dart`

**Interfaces:**
- Produces: `TimetableOcrEngine.recognize(OcrImageRequest) -> Future<OcrDocument>`
- Produces: `OcrImageRequest(path, cropRect?, quarterTurns, languageTag)`
- Produces: `OcrDocument(width, height, textAngle, lines)` and word rectangles
- Method channel: `personal_planner/timetable_ocr`, method `recognize`
- Error codes: `language_unavailable`, `image_too_large`, `decode_failed`, `recognition_failed`

- [ ] **Step 1: Write failing contract and channel tests**

Mock the method channel and assert request serialization, word-bound deserialization, nullable text angle, and each platform error mapping. Assert unsupported platforms return a typed unavailable result rather than throwing an opaque platform exception.

- [ ] **Step 2: Run Dart tests and verify failure**

Run: `flutter test test/domain/timetable_ocr_contract_test.dart test/platform/windows_timetable_ocr_test.dart`

Expected: FAIL because the OCR port and adapter do not exist.

- [ ] **Step 3: Implement the Dart port and Windows method-channel client**

Keep platform maps inside `WindowsTimetableOcr`; domain objects contain no Flutter types. Use normalized crop coordinates and `quarterTurns` 0–3 in the request.

- [ ] **Step 4: Implement C++/WinRT recognition**

Initialize the channel from `FlutterWindow`. Decode the selected file into `SoftwareBitmap`, apply crop/rotation, select `zh-Hans` through `OcrEngine::IsLanguageSupported`/`TryCreateFromLanguage`, enforce `OcrEngine::MaxImageDimension`, call `RecognizeAsync`, and return lines/words with `Text`, `BoundingRect`, plus `OcrResult::TextAngle`. Link `windowsapp` in CMake. Never return the image bytes or path in an error message.

- [ ] **Step 5: Run tests and a Windows build**

Run:

```powershell
flutter test test/domain/timetable_ocr_contract_test.dart test/platform/windows_timetable_ocr_test.dart
flutter build windows --debug
```

Expected: tests pass and the C++ runner links successfully.

- [ ] **Step 6: Commit**

```powershell
git add lib/domain/ocr lib/platform/ocr windows/runner test/domain/timetable_ocr_contract_test.dart test/platform/windows_timetable_ocr_test.dart
git commit -m "feat: add local Windows timetable OCR"
```

### Task 3: Parse OCR geometry into editable course drafts

**Files:**
- Create: `lib/domain/models/timetable_import.dart`
- Create: `lib/domain/services/timetable_parser.dart`
- Create: `test/fixtures/timetable/desktop_grid_ocr.json`
- Create: `test/fixtures/timetable/mobile_grid_ocr.json`
- Create: `test/domain/timetable_parser_test.dart`

**Interfaces:**
- Produces: `TimetableParser.parse(OcrDocument) -> TimetableDraft`
- Produces: `CourseDraft(name, teacher, location, weekday, startPeriod, endPeriod, weekSpans, areaId?, projectId?, reviewReasons)`
- Produces: `WeekSpan(startWeek, endWeek, parity)` where parity is every/odd/even
- Produces typed review reasons: missingName, missingWeeks, ambiguousWeekday, ambiguousPeriods, invalidRange, unparsedText

- [ ] **Step 1: Create deterministic OCR fixtures and failing parser tests**

Fixtures contain only synthetic text/bounds, not the user’s raw screenshots. Assert parsing for `1–16周`, `1–13周`, `2–6(双周)`, `1–4周`, multi-line names, teacher/location suffixes, and geometry-only period spans. Assert ambiguous cells remain drafts with review reasons rather than being dropped.

- [ ] **Step 2: Run parser tests and verify failure**

Run: `flutter test test/domain/timetable_parser_test.dart`

Expected: FAIL because parser types do not exist.

- [ ] **Step 3: Implement staged parsing**

Implement small pure functions for text normalization, weekday band detection, period-row detection, cell grouping, week-range parsing, and teacher/location extraction. Use word-center coordinates to assign columns/rows; preserve original cell text on every draft for manual correction.

- [ ] **Step 4: Run tests and verify pass**

Run: `flutter test test/domain/timetable_parser_test.dart`

Expected: PASS for desktop and mobile layouts.

- [ ] **Step 5: Commit**

```powershell
git add lib/domain/models/timetable_import.dart lib/domain/services/timetable_parser.dart test/fixtures/timetable test/domain/timetable_parser_test.dart
git commit -m "feat: parse timetable OCR into course drafts"
```

### Task 4: Build no-write preview, occurrence expansion, conflict, and duplicate detection

**Files:**
- Create: `lib/application/timetable_conflict_detector.dart`
- Create: `lib/application/timetable_import_service.dart`
- Create: `test/application/timetable_conflict_detector_test.dart`
- Create: `test/application/timetable_import_preview_test.dart`

**Interfaces:**
- Produces: `TimetableImportService.preview(TimetableDraft, AcademicTerm, PeriodTemplate) -> Future<TimetableImportPreview>`
- Produces: `TimetableImportPreview(series, occurrences, conflicts, duplicates, reviewReasons)`
- Produces exact duplicate key from normalized name, weekday, periods, week spans, parity, and term
- No repository write methods are called by `preview`

- [ ] **Step 1: Write failing preview tests**

Assert: 1–16 weekly expands to 16 occurrences; 2–6 even expands to weeks 2, 4, 6; consecutive periods use first start and last end; non-contiguous spans create separate series; fixed-event overlaps become conflicts; exact duplicates default to skip; teacher/location-only differences become possible updates; preview invokes no writes.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/application/timetable_conflict_detector_test.dart test/application/timetable_import_preview_test.dart`

Expected: FAIL because preview services do not exist.

- [ ] **Step 3: Implement deterministic preview**

Convert each week span to a `RecurrenceRule` using the academic term’s first Monday and the period template. Reuse `RecurrenceExpander` for concrete dates. Query existing calendar occurrences only for the term window. Sort all preview output by course, weekday, start time, then local date for stable UI/tests.

- [ ] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS and repository spies report zero writes.

- [ ] **Step 5: Commit**

```powershell
git add lib/application/timetable_conflict_detector.dart lib/application/timetable_import_service.dart test/application/timetable_conflict_detector_test.dart test/application/timetable_import_preview_test.dart
git commit -m "feat: preview timetable imports and conflicts"
```

### Task 5: Commit and rollback import batches atomically

**Files:**
- Create: `lib/domain/repositories/timetable_import_repository.dart`
- Create: `lib/data/repositories/drift_timetable_import_repository.dart`
- Modify: `lib/application/timetable_import_service.dart`
- Create: `test/data/timetable_import_repository_test.dart`
- Create: `test/application/timetable_import_commit_test.dart`
- Create: `test/application/timetable_import_rollback_test.dart`

**Interfaces:**
- Produces: `commit(TimetableImportCommit) -> Future<TimetableImportBatch>`
- Produces: `inspectRollback(batchId) -> Future<RollbackPreview>`
- Produces: `rollback(batchId, {Set<String> forceEventIds = const {}}) -> Future<RollbackResult>`
- Emits one `ScheduleInputChange` after a successful transaction

- [ ] **Step 1: Write failing transaction tests**

Assert a commit creates one batch plus all anchors/rules, marks events locked and `sourceKind=timetableImport`, and rolls back everything on an injected failure. Assert same image hash + term is surfaced as a duplicate batch. Assert rollback deletes untouched imports, protects events whose `updatedAtUtc` changed or that gained exceptions, and succeeds only for explicitly forced protected IDs.

- [ ] **Step 2: Run tests and verify failure**

Run: `flutter test test/data/timetable_import_repository_test.dart test/application/timetable_import_commit_test.dart test/application/timetable_import_rollback_test.dart`

Expected: FAIL because batch repository operations do not exist.

- [ ] **Step 3: Implement the Drift transaction and service callbacks**

Insert batch, recurrence rules, and event anchors in one `database.transaction`. Use one `logicalCourseId` for all time/range series originating from the same reviewed course. Save SHA-256 and base filename only. For rollback, compare current event/exception state with imported state before deletion and mark the batch `rolledBack` in the same transaction.

- [ ] **Step 4: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS, including injected failures and protected edits.

- [ ] **Step 5: Commit**

```powershell
git add lib/domain/repositories/timetable_import_repository.dart lib/data/repositories/drift_timetable_import_repository.dart lib/application/timetable_import_service.dart test/data/timetable_import_repository_test.dart test/application/timetable_import_commit_test.dart test/application/timetable_import_rollback_test.dart
git commit -m "feat: commit and undo timetable import batches"
```

### Task 6: Build the approved five-step import wizard

**Files:**
- Create: `lib/features/calendar/timetable_import/timetable_import_page.dart`
- Create: `lib/features/calendar/timetable_import/timetable_import_controller.dart`
- Create: `lib/features/calendar/timetable_import/upload_step.dart`
- Create: `lib/features/calendar/timetable_import/review_step.dart`
- Create: `lib/features/calendar/timetable_import/term_step.dart`
- Create: `lib/features/calendar/timetable_import/period_step.dart`
- Create: `lib/features/calendar/timetable_import/preview_step.dart`
- Modify: `lib/features/calendar/week_view/week_view_page.dart`
- Modify: `lib/app/router.dart`
- Modify: `lib/app/planner_app.dart`
- Modify: `lib/main.dart`
- Create: `test/features/calendar/timetable_import_page_test.dart`
- Modify: `test/features/calendar/week_view_test.dart`
- Create: `test/app/timetable_import_route_test.dart`

**Interfaces:**
- Produces route: `/calendar/import`
- Produces calendar action key: `import-timetable`
- Wizard steps: upload, review, term, periods, preview
- Consumes: `TimetableOcrEngine`, `TimetableParser`, `AcademicCalendarService`, `TimetableImportService`, `WorkspaceService`

- [ ] **Step 1: Write failing wizard tests with fake OCR**

Assert the calendar action opens the route; image selection starts local recognition; language-unavailable shows manual-entry action; review rows can add/delete/edit courses and area/project; back/next preserves edits; week number and first Monday update each other; period rows validate; final preview shows counts/conflicts/duplicates; commit is disabled while unresolved review reasons remain.

- [ ] **Step 2: Run widget and route tests and verify failure**

Run: `flutter test test/features/calendar/timetable_import_page_test.dart test/features/calendar/week_view_test.dart test/app/timetable_import_route_test.dart`

Expected: FAIL because the route and wizard do not exist.

- [ ] **Step 3: Implement controller-owned wizard state**

Keep the selected file path and editable draft in the controller until completion/cancel. Step widgets are presentational and receive immutable state plus callbacks. Default the course area to 学业 and filter optional projects by that area. Allow crop/quarter-turn updates to trigger explicit re-recognition, not silent background replacement.

- [ ] **Step 4: Implement preview actions and commit feedback**

Each conflict supports skip course, exclude occurrence, or mark pending; each duplicate supports skip/update/create. Show exact course/series/occurrence counts. After commit, return to calendar, trigger the existing replan preview/auto-adjust policy, and offer “撤销本次导入”.

- [ ] **Step 5: Run tests and verify pass**

Run the command from Step 2.

Expected: PASS at 1280px and 800px surfaces without overflow, with back navigation preserving state.

- [ ] **Step 6: Commit**

```powershell
git add lib/features/calendar/timetable_import lib/features/calendar/week_view/week_view_page.dart lib/app/router.dart lib/app/planner_app.dart lib/main.dart test/features/calendar/timetable_import_page_test.dart test/features/calendar/week_view_test.dart test/app/timetable_import_route_test.dart
git commit -m "feat: add guided timetable import wizard"
```

### Task 7: Verify privacy, recovery, scheduling integration, and Windows packaging

**Files:**
- Modify: `test/architecture/no_network_test.dart`
- Create: `test/application/timetable_import_privacy_test.dart`
- Create: `integration_test/timetable_import_flow_test.dart`
- Modify: `docs/智能日程使用教程.md`
- Modify: `docs/testing/manual-windows-checklist.md`
- Modify: `pubspec.yaml` for the next application/build version only after all tests pass

**Interfaces:**
- End-to-end fixture uses fake OCR; native OCR gets a separate manual Windows smoke check
- Release artifact must include the updated Windows runner

- [ ] **Step 1: Add failing privacy and end-to-end assertions**

Assert no HTTP client/network dependency is introduced; diagnostic output and backup/export facts contain no raw image path or bytes; imported course occurrences block movable-task scheduling; batch rollback restores the pre-import calendar and produces a replan preview.

- [ ] **Step 2: Run focused integration tests and verify failure**

Run: `flutter test test/architecture/no_network_test.dart test/application/timetable_import_privacy_test.dart integration_test/timetable_import_flow_test.dart -d windows`

Expected: FAIL until all wiring and privacy filters are complete.

- [ ] **Step 3: Complete assembly, documentation, and version bump**

Wire production OCR/import repositories in `main.dart`; document the five steps, language-pack fallback, manual correction, conflict choices, and batch undo. Add manual checks for a real Chinese screenshot, missing OCR language, rotated/cropped images, duplicate import, and modified-event rollback. Increment `version` and `msix_version` consistently.

- [ ] **Step 4: Run full verification**

Run:

```powershell
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
flutter test integration_test -d windows
flutter build windows --release
```

Expected: all tests pass, analyzer reports no issues, and the release EXE launches with the OCR method channel registered.

- [ ] **Step 5: Perform the manual Windows OCR smoke check**

Use a copied non-sensitive timetable fixture. Verify local recognition, edit preservation, exact odd/even occurrences, no network traffic, re-import skip, and batch undo. Record results in `docs/testing/flow-verification.md`.

- [ ] **Step 6: Commit**

```powershell
git add test/architecture test/application/timetable_import_privacy_test.dart integration_test/timetable_import_flow_test.dart docs pubspec.yaml pubspec.lock
git commit -m "test: verify local timetable import flow"
```
