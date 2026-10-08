// Task 12A Step 3（用户 2026-10-08 追加的发布阻断项）：输入规范化。
//
// **要修的是什么**：`TaskDraft` 收什么就存什么，只校验 `min > 0` 且 `min <= max`。
// 于是把预计时长改成 15 分钟、而片段仍是默认 30–90 时，库里就存下一条
// `estimatedMinutes = 15, minChunk = 30` 的任务——**一条自相矛盾的记录**：它声明"每段至少
// 30 分钟"，却总共只有 15 分钟可做。候选生成在 Step 1／2 已经能兜住这种情况，但那是补救；
// 正确的做法是**根本不要存下无意义的设置**。
//
// 规则（路线图 Task 12A 的 Interfaces）：
// - 预计时长缩短后，片段上下限**同步夹紧到合法范围**（不大于总时长）；
// - **服务层与界面层得到同一结果**——所以规范化放在服务层（唯一入口），不是各处各自判断；
// - 只有"无法解释的非法组合"才拒绝（`min <= 0`、`max < min`）。
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/domain/repositories/task_repository.dart';

final class _Clock implements Clock {
  const _Clock();
  @override
  DateTime nowUtc() => DateTime.utc(2026, 10, 8, 8);
}

final class _Ids implements IdGenerator {
  var _n = 0;
  @override
  String next() => 'task-${++_n}';
}

final class _Tasks implements TaskRepository {
  final Map<String, PlannerTask> saved = {};

  @override
  Stream<List<PlannerTask>> watchAllTasks() =>
      Stream.value(saved.values.toList());

  @override
  Stream<List<PlannerTask>> watchOpenTasks() => Stream.value(
    saved.values.where((task) => task.status == TaskStatus.open).toList(),
  );

  @override
  Future<PlannerTask?> getById(String id) async => saved[id];

  @override
  Future<void> save(PlannerTask task) async => saved[task.id] = task;
}

({TaskService service, _Tasks repository}) build() {
  final repository = _Tasks();
  return (
    service: TaskService(
      repository: repository,
      clock: const _Clock(),
      idGenerator: _Ids(),
    ),
    repository: repository,
  );
}

TaskDraft draft({
  required int estimatedMinutes,
  required int minChunk,
  required int maxChunk,
  TaskSplitMode splitMode = TaskSplitMode.splittable,
}) => TaskDraft(
  title: '算法作业',
  estimatedMinutes: estimatedMinutes,
  areaId: 'area-study',
  splitMode: splitMode,
  minChunkMinutes: minChunk,
  maxChunkMinutes: maxChunk,
);

void main() {
  group('Step 3：新建时把片段范围夹紧到合法范围', () {
    test('预计 15 分钟、片段 30–90 ⇒ 存下来的上下限都不超过 15', () async {
      final h = build();
      final result = await h.service.saveDraft(
        draft(estimatedMinutes: 15, minChunk: 30, maxChunk: 90),
      );

      expect(result.isSuccess, isTrue, reason: '这是可规范化的输入，不该被拒绝');
      final task = result.task!;
      expect(
        task.minChunkMinutes,
        lessThanOrEqualTo(15),
        reason: '"每段至少 30 分钟"而总共只有 15 分钟，是一条自相矛盾的记录',
      );
      expect(task.maxChunkMinutes, lessThanOrEqualTo(15));
      expect(
        task.minChunkMinutes,
        lessThanOrEqualTo(task.maxChunkMinutes),
        reason: '夹紧之后仍必须满足 min <= max',
      );
    });

    test('预计时长够长时**不动**用户填的范围（不能顺手改写合法输入）', () async {
      final h = build();
      final result = await h.service.saveDraft(
        draft(estimatedMinutes: 120, minChunk: 30, maxChunk: 90),
      );

      expect(result.task!.minChunkMinutes, 30);
      expect(result.task!.maxChunkMinutes, 90);
    });

    test('一半合法：预计 15 分钟、片段 5–90 ⇒ 只夹上限，下限保持 5', () async {
      final h = build();
      final result = await h.service.saveDraft(
        draft(estimatedMinutes: 15, minChunk: 5, maxChunk: 90),
      );

      expect(result.task!.minChunkMinutes, 5, reason: '5 ≤ 15，这条约束本来就成立');
      expect(result.task!.maxChunkMinutes, lessThanOrEqualTo(15));
    });

    test('连续任务不看片段范围：两边都被设成整段时长（既有行为不变）', () async {
      final h = build();
      final result = await h.service.saveDraft(
        draft(
          estimatedMinutes: 15,
          minChunk: 15,
          maxChunk: 15,
          splitMode: TaskSplitMode.continuous,
        ),
      );

      expect(result.task!.minChunkMinutes, 15);
      expect(result.task!.maxChunkMinutes, 15);
    });
  });

  group('Step 3：编辑时同样夹紧（缩短预计时长是主要场景）', () {
    test('把已有的 120 分钟任务改成 15 分钟 ⇒ 片段范围跟着收紧', () async {
      final h = build();
      final created = await h.service.saveDraft(
        draft(estimatedMinutes: 120, minChunk: 30, maxChunk: 90),
      );
      final id = created.task!.id;

      final updated = await h.service.updateDraft(
        id,
        draft(estimatedMinutes: 15, minChunk: 30, maxChunk: 90),
      );

      expect(updated.isSuccess, isTrue);
      // **这里我原先断言 `estimatedMinutes == 15`，是错的**：`updateDraft` 刻意不改
      // `estimatedMinutes` / `remainingMinutes`——预计时长是"计划做多久"，剩余时长是"还没做完
      // 多少"，改计划不应该凭空改写"还剩多少工作"。真正会缩短这两个值的是专注记录与手动修正
      // （`correctRemainingMinutes`）。这一组要验的是**片段范围**，所以只断言片段。
      expect(
        updated.task!.minChunkMinutes,
        lessThanOrEqualTo(15),
        reason: '缩短预计时长之后仍要满足"片段不长于总时长"',
      );
      expect(updated.task!.maxChunkMinutes, lessThanOrEqualTo(15));
    });

    test('编辑后的规范化值真的落库（不只是返回值好看）', () async {
      final h = build();
      final created = await h.service.saveDraft(
        draft(estimatedMinutes: 120, minChunk: 30, maxChunk: 90),
      );
      final id = created.task!.id;

      await h.service.updateDraft(
        id,
        draft(estimatedMinutes: 15, minChunk: 30, maxChunk: 90),
      );

      final stored = h.repository.saved[id]!;
      expect(stored.minChunkMinutes, lessThanOrEqualTo(15));
      expect(stored.maxChunkMinutes, lessThanOrEqualTo(15));
    });
  });

  group('Step 3：无法解释的非法组合仍然拒绝', () {
    test('下限为 0 ⇒ 拒绝（这不是"可以夹紧"，是没有输入）', () async {
      final h = build();
      final result = await h.service.saveDraft(
        draft(estimatedMinutes: 120, minChunk: 0, maxChunk: 90),
      );

      expect(result.isSuccess, isFalse);
      expect(result.fieldErrors['chunks'], isNotNull);
    });

    test('上限小于下限 ⇒ 拒绝（用户把两个框填反了，夹紧会掩盖它）', () async {
      final h = build();
      final result = await h.service.saveDraft(
        draft(estimatedMinutes: 120, minChunk: 90, maxChunk: 30),
      );

      expect(result.isSuccess, isFalse);
      expect(result.fieldErrors['chunks'], isNotNull);
    });
  });
}
