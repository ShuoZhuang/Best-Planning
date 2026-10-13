import 'package:personal_planner/core/clock.dart';
import 'package:personal_planner/core/ids.dart';
import 'package:personal_planner/core/area_palette.dart';
import 'package:personal_planner/domain/models/workspace.dart';
import 'package:personal_planner/domain/repositories/workspace_repository.dart';

/// 首次运行要建立的默认领域。
///
/// 默认领域覆盖大学生日常任务的主要归属，生活领域默认计入个人生活时间。
final class DefaultAreas {
  const DefaultAreas._();

  static const List<({String name, bool isLife})> entries = [
    (name: '学业', isLife: false),
    (name: '科研', isLife: false),
    (name: '竞赛', isLife: false),
    (name: '工作', isLife: false),
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
    this.onWorkspaceChanged,
  });

  final WorkspaceRepository repository;
  final Clock clock;
  final IdGenerator idGenerator;

  /// **会改变日历分类名称或颜色**的领域写入成功之后的日历失效信号（计划 §2.6）。
  ///
  /// 只有四类写入发它：新建领域、领域改名、改领域颜色，以及补齐默认领域时**真的新建了**。
  /// 理由是日历卡片与图例直接显示领域的名称与颜色，改了它们而不知道就等于"改了颜色但日历
  /// 还是旧色"。
  ///
  /// **不发的**：生活标记（[setAreaLife]）、项目的新建／改名／归档——它们不进入日历卡片的
  /// 名称或颜色，发信号只会让三个页面白读一次库（§2.6："不影响卡片展示的项目变化不发"）。
  ///
  /// 允许为空以保持测试替身轻量；生产组合根必须装配到那唯一的失效总线上。
  final void Function()? onWorkspaceChanged;

  Future<List<PlannerArea>> listAreas() => repository.listAreas();

  Future<List<PlannerProject>> listProjects() => repository.listProjects();

  /// 新建领域，排序追加到末尾，因此建立顺序即用户看到的顺序。
  Future<PlannerArea> createArea(String name, {bool isLife = false}) async {
    final existing = await repository.listAreas();
    final now = clock.nowUtc();
    final sortOrder = existing.isEmpty
        ? 0
        : existing
                  .map((area) => area.sortOrder)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    final area = PlannerArea(
      id: idGenerator.next(),
      name: name,
      color: _nextAreaColor(existing, sortOrder),
      sortOrder: sortOrder,
      isLife: isLife,
      createdAtUtc: now,
      updatedAtUtc: now,
    );
    await repository.saveArea(area);
    // 新领域就是一个新的日历分类（名称＋颜色），因此它同样要刷新。
    onWorkspaceChanged?.call();
    return area;
  }

  /// 改名。只推进修改时间，创建时间保持不变（FR-DATA-08）。
  Future<void> renameArea(PlannerArea area, String name) async {
    await repository.saveArea(
      area.copyWith(name: name, updatedAtUtc: clock.nowUtc()),
    );
    // 日历卡片与图例显示的就是这个名字：写入成功之后必须让视图读回新名字。
    onWorkspaceChanged?.call();
  }

  /// 设置或取消生活标记。这是**唯一**能让生活配额与"生活"分类生效的操作。
  Future<void> setAreaLife(PlannerArea area, bool isLife) => repository
      .saveArea(area.copyWith(isLife: isLife, updatedAtUtc: clock.nowUtc()));

  Future<void> setAreaColor(String areaId, int colorArgb) async {
    if (!isOpaqueArgb(colorArgb)) {
      throw ArgumentError.value(
        colorArgb,
        'colorArgb',
        'Must be an opaque 32-bit ARGB color.',
      );
    }
    final areas = await repository.listAreas();
    final index = areas.indexWhere((area) => area.id == areaId);
    if (index < 0) {
      throw ArgumentError.value(areaId, 'areaId', '领域不存在');
    }
    await repository.saveArea(
      areas[index].copyWith(color: colorArgb, updatedAtUtc: clock.nowUtc()),
    );
    // 领域颜色直接画在日历卡片上（`ScheduleColorService.loadCatalog` 读它）。
    onWorkspaceChanged?.call();
  }

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
  Future<void> renameProject(PlannerProject project, String name) => repository
      .saveProject(project.copyWith(name: name, updatedAtUtc: clock.nowUtc()));

  /// 补齐缺少的默认领域，返回新建数量。
  ///
  /// 名称比较忽略首尾空白和大小写，保留所有现有领域；新增项从当前最大排序值后追加。
  Future<int> ensureDefaultAreas() async {
    final existing = await repository.listAreas();
    final existingNames = existing
        .map((area) => area.name.trim().toLowerCase())
        .toSet();

    var order = existing.isEmpty
        ? 0
        : existing
                  .map((area) => area.sortOrder)
                  .reduce((a, b) => a > b ? a : b) +
              1;
    var created = 0;
    final usedColors = existing
        .map((area) => resolveAreaColorArgb(area.color, area.sortOrder))
        .toSet();
    for (final entry in DefaultAreas.entries) {
      if (existingNames.contains(entry.name.trim().toLowerCase())) continue;
      final now = clock.nowUtc();
      final areaOrder = order++;
      final color = _nextAreaColorFromUsed(usedColors, areaOrder);
      await repository.saveArea(
        PlannerArea(
          id: idGenerator.next(),
          name: entry.name,
          color: color,
          sortOrder: areaOrder,
          isLife: entry.isLife,
          createdAtUtc: now,
          updatedAtUtc: now,
        ),
      );
      existingNames.add(entry.name.trim().toLowerCase());
      usedColors.add(color);
      created++;
    }
    // **只有真的新建了才发**：一个都没建时这次调用没有改变任何分类，发信号只是白刷。
    if (created > 0) onWorkspaceChanged?.call();
    return created;
  }
}

int _nextAreaColor(List<PlannerArea> existing, int sortOrder) =>
    _nextAreaColorFromUsed(
      existing
          .map((area) => resolveAreaColorArgb(area.color, area.sortOrder))
          .toSet(),
      sortOrder,
    );

int _nextAreaColorFromUsed(Set<int> usedColors, int sortOrder) {
  for (final color in areaPaletteArgb) {
    if (!usedColors.contains(color)) return color;
  }
  return resolveAreaColorArgb(0, sortOrder);
}
