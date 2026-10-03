import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/tag.dart';
import 'package:personal_planner/domain/repositories/tag_repository.dart';

/// 标签的读写服务。
///
/// 只做三件事：分配 id 与时戳、保证同名标签不会出现两行、把"设置某个任务的标签"实现为
/// 差量更新。哪些标签有意义是用户的决定，不是代码的判断。
final class TagService {
  const TagService({
    required this.repository,
    required this.clock,
    required this.idGenerator,
  });

  final TagRepository repository;
  final Clock clock;
  final IdGenerator idGenerator;

  Future<List<PlannerTag>> listTags() => repository.listTags();

  Future<List<PlannerTag>> tagsForTask(String taskId) =>
      repository.tagsForTask(taskId);

  /// 全部标签的名称集合，供统计筛选列出可选项。
  Future<Set<String>> allTagNames() async => {
    for (final tag in await repository.listTags()) tag.name,
  };

  /// 按名称取得标签，不存在则建立。
  ///
  /// 名称是标签对用户的标识，因此先查后建；数据库没有唯一约束（那需要一次 schema
  /// 迁移），"同名只有一行"这条约定由这里保证。
  Future<PlannerTag> ensureTag(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', '标签名不能为空');
    }
    final known = await _byName();
    return known[trimmed] ?? _create(trimmed, known);
  }

  /// 把某个任务的标签整体设为 [tagNames]（按名称）。
  ///
  /// 只做差量：已在任务上的标签不重复建立关联，不在其中的才解除，因此反复保存同一组标签
  /// 不会产生多余写入，也不会把"最近修改"无谓推进。
  Future<void> setTaskTags(String taskId, Iterable<String> tagNames) async {
    final wanted = <String>{};
    for (final name in tagNames) {
      final trimmed = name.trim();
      if (trimmed.isEmpty) continue;
      wanted.add(trimmed);
    }

    final known = await _byName();
    final desired = <PlannerTag>[
      for (final name in wanted) known[name] ?? await _create(name, known),
    ];

    final current = await repository.tagsForTask(taskId);
    final currentIds = {for (final tag in current) tag.id};
    final desiredIds = {for (final tag in desired) tag.id};
    for (final tag in desired) {
      if (currentIds.contains(tag.id)) continue;
      await repository.linkTag(taskId, tag.id, clock.nowUtc());
    }
    for (final tag in current) {
      if (desiredIds.contains(tag.id)) continue;
      await repository.unlinkTag(taskId, tag.id);
    }
  }

  Future<Map<String, PlannerTag>> _byName() async => {
    for (final tag in await repository.listTags()) tag.name: tag,
  };

  /// 建立标签，并把它登记进 [known]，避免同一批里为同一个名称建出两行。
  Future<PlannerTag> _create(String name, Map<String, PlannerTag> known) async {
    final now = clock.nowUtc();
    final tag = PlannerTag(
      id: idGenerator.next(),
      name: name,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repository.saveTag(tag);
    known[name] = tag;
    return tag;
  }
}
