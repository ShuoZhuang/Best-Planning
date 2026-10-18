import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/data/database/app_database.dart';
import 'package:personal_planner/data/repositories/drift_preference_rule_repository.dart';
import 'package:personal_planner/domain/models/preference_snapshot.dart';
import 'package:personal_planner/domain/repositories/preference_rule_repository.dart';

LearnedPreferenceRule _rule({
  required String id,
  required String subject,
  LearnedPreferenceKind kind = LearnedPreferenceKind.preferredTimeWindow,
  LearnedPreferenceStatus status = LearnedPreferenceStatus.confirmed,
  int updatedMinute = 0,
  int? start,
  int? end,
  int? focus,
  String evidenceVersion = 'v1',
}) => LearnedPreferenceRule(
  id: id,
  kind: kind,
  subjectKey: subject,
  status: status,
  confidencePermille: 800,
  source: 'test',
  evidenceVersion: evidenceVersion,
  updatedAtUtc: DateTime.utc(2026, 10, 1, 0, updatedMinute),
  preferredStartMinute: start,
  preferredEndMinute: end,
  preferredFocusMinutes: focus,
);

void main() {
  late AppDatabase database;
  late DriftPreferenceRuleRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = DriftPreferenceRuleRepository(database);
  });

  tearDown(() => database.close());

  test('保存后按 subject/kind/updated/id 稳定排序', () async {
    await repository.save(
      _rule(id: 'b', subject: 'global', start: 600, end: 720),
    );
    await repository.save(
      _rule(id: 'a', subject: 'area:study', start: 480, end: 600),
    );
    final all = await repository.listAll();
    expect(all.map((rule) => rule.id), ['a', 'b']);
    expect(all.first.kind, LearnedPreferenceKind.preferredTimeWindow);
    expect(all.first.preferredStartMinute, 480);
  });

  test('saveAllAtomically 写入全部规则，clear 只清规则', () async {
    await repository.saveAllAtomically([
      _rule(id: 'a', subject: 'area:study', start: 480, end: 600),
      _rule(
        id: 'b',
        subject: 'area:study',
        kind: LearnedPreferenceKind.preferredFocusMinutes,
        focus: 45,
      ),
    ]);
    expect(await repository.listForSubject('area:study'), hasLength(2));
    // 证据表不受影响。
    await database
        .into(database.preferenceEvidence)
        .insert(
          PreferenceEvidenceCompanion.insert(
            id: 'ev',
            kind: 'focusCompletion',
            subjectKey: 'area:study',
            observedAtUtc: 1,
            metadataJson: '{}',
          ),
        );
    await repository.clearLearnedRules();
    expect(await repository.listAll(), isEmpty);
    expect(
      await database.select(database.preferenceEvidence).get(),
      hasLength(1),
    );
  });

  test('快照只消费 confirmed，edited/suggested/disabled 不生效', () {
    final snapshot = PreferenceSnapshot.fromRules(
      enabled: true,
      rules: [
        _rule(id: 'area-time', subject: 'area:study', start: 480, end: 600),
        _rule(
          id: 'area-focus',
          subject: 'area:study',
          kind: LearnedPreferenceKind.preferredFocusMinutes,
          focus: 45,
        ),
        _rule(
          id: 'work-time',
          subject: 'area:work',
          start: 720,
          end: 900,
          status: LearnedPreferenceStatus.edited,
        ),
        _rule(id: 'global-time', subject: 'global', start: 600, end: 720),
      ],
    );

    final study = snapshot.forTask(areaId: 'study');
    expect(study?.preferredWindow?.startMinute, 480);
    expect(study?.preferredFocusMinutes, 45);
    // 领域偏好只作用于该领域：工作任务回退到 global，而不是拿到学习领域的时段。
    final work = snapshot.forTask(areaId: 'work');
    expect(work?.preferredWindow?.startMinute, 600);
    // 无领域任务只用 global。
    expect(snapshot.forTask(areaId: null)?.preferredWindow?.startMinute, 600);
    // 全局样本不能反推某个领域偏好。
    expect(
      snapshot.forSubject('area:study')?.preferredWindow?.startMinute,
      480,
    );
  });

  test('学习关闭时所有任务都没有偏好', () {
    final snapshot = PreferenceSnapshot.fromRules(
      enabled: false,
      rules: [_rule(id: 'a', subject: 'global', start: 480, end: 600)],
    );
    expect(snapshot.forTask(areaId: null), isNull);
    expect(snapshot.forTask(areaId: 'study'), isNull);
  });

  test('确认/撤销会改变 evidenceVersion，从而改变输入哈希', () {
    final before = PreferenceSnapshot.fromRules(
      enabled: true,
      rules: [_rule(id: 'a', subject: 'global', start: 480, end: 600)],
    );
    final after = PreferenceSnapshot.fromRules(
      enabled: true,
      rules: [
        _rule(
          id: 'a',
          subject: 'global',
          start: 480,
          end: 600,
          status: LearnedPreferenceStatus.disabled,
        ),
      ],
    );
    expect(before.evidenceVersion, isNot(after.evidenceVersion));
    expect(after.hasAny, isFalse);
  });
}
