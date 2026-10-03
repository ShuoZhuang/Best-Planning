import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';

/// 首次运行要建立的默认领域。
///
/// 需求 §4.1 以"学业、科研、生活"为例，首次引导也已按"生活娱乐"的口径给出配额，
/// 但生活标记只存在于领域上——领域不存在，标记就无人赋值，生活配额与统计的"生活"
/// 分类也就都不会生效。因此默认领域不是装饰性的示例数据，而是这两条链路的前置条件。
final class DefaultAreas {
  const DefaultAreas._();

  static const List<({String name, bool isLife})> entries = [
    (name: '学业', isLife: false),
    (name: '科研', isLife: false),
    (name: '生活', isLife: true),
  ];
}

/// 领域与项目的读写服务。
///
/// 只做三件事：分配 id 与时戳、维护 `sortOrder`、校验层次关系（项目必须挂在已存在的
/// 领域下）。业务规则不在这里——"哪些领域算生活"是用户的标记，不是代码的判断。
final class WorkspaceService {
  const WorkspaceService({
    required this.repository,
    required this.clock,
    required this.idGenerator,
  });

  final WorkspaceRepository repository;
  final Clock clock;
  final IdGenerator idGenerator;

  Future<List<PlannerArea>> listAreas() => repository.listAreas();

  Future<List<PlannerProject>> listProjects() => repository.listProjects();

  /// 新建领域，排序追加到末尾，因此建立顺序即用户看到的顺序。
  Future<PlannerArea> createArea(String name, {bool isLife = false}) async {
    final existing = await repository.listAreas();
    final now = clock.nowUtc();
    final area = PlannerArea(
      id: idGenerator.next(),
      name: name,
      color: 0,
      sortOrder: existing.isEmpty ? 0 : existing.last.sortOrder + 1,
      isLife: isLife,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repository.saveArea(area);
    return area;
  }

  /// 改名。只推进修改时间，创建时间保持不变（FR-DATA-08）。
  Future<void> renameArea(PlannerArea area, String name) => repository.saveArea(
    area.copyWith(name: name, updatedAtUtc: clock.nowUtc()),
  );

  /// 设置或取消生活标记。这是**唯一**能让生活配额与"生活"分类生效的操作。
  Future<void> setAreaLife(PlannerArea area, bool isLife) => repository.saveArea(
    area.copyWith(isLife: isLife, updatedAtUtc: clock.nowUtc()),
  );

  /// 新建项目。
  ///
  /// 领域必须已存在：项目是任务通向领域的唯一路径，挂到一个不存在的领域上会让统计与
  /// 生活标记都指向空归属，而且这种数据从界面上看不出来。
  Future<PlannerProject> createProject({
    required String name,
    required String areaId,
  }) async {
    final areas = await repository.listAreas();
    if (!areas.any((area) => area.id == areaId)) {
      throw ArgumentError.value(areaId, 'areaId', '领域不存在');
    }
    final now = clock.nowUtc();
    final project = PlannerProject(
      id: idGenerator.next(),
      areaId: areaId,
      name: name,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repository.saveProject(project);
    return project;
  }

  /// 归档或取消归档项目。归档是状态而不是删除，因此可逆。
  Future<void> archiveProject(
    PlannerProject project, {
    required bool archived,
  }) => repository.saveProject(
    project.copyWith(
      archivedAtUtc: archived ? clock.nowUtc() : null,
      updatedAtUtc: clock.nowUtc(),
    ),
  );

  /// 项目改名。与领域改名同口径：只推进修改时间，创建时间保持不变。
  Future<void> renameProject(PlannerProject project, String name) =>
      repository.saveProject(
        project.copyWith(name: name, updatedAtUtc: clock.nowUtc()),
      );

  /// 首次运行时建立默认领域，返回新建数量。
  ///
  /// 只在**一个领域都没有**时写入：这是"初始化"而不是"补齐"。用户删掉某个默认领域是
  /// 明确的意图，下次启动不该把它加回来；已有领域时直接返回 0，因此重复调用是安全的。
  Future<int> ensureDefaultAreas() async {
    if ((await repository.listAreas()).isNotEmpty) return 0;

    var order = 0;
    for (final entry in DefaultAreas.entries) {
      final now = clock.nowUtc();
      await repository.saveArea(
        PlannerArea(
          id: idGenerator.next(),
          name: entry.name,
          color: 0,
          sortOrder: order++,
          isLife: entry.isLife,
          createdAtUtc: now,
          updatedAtUtc: now,
        ),
      );
    }
    return DefaultAreas.entries.length;
  }
}
