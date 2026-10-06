import 'package:flutter/material.dart';
import 'package:personal_planner/application/workspace_service.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/workspace.dart';

/// 领域与项目的管理界面：新建、改名、标记生活、归档。
///
/// 需求 FR-TASK-02 要求任务能归属领域与项目，FR-STAT-02 要求按领域与项目筛选统计，
/// 而"生活标记"按 R13 的决策只存在于**领域**上（任务经"任务 → 项目 → 领域"推导）。
/// 因此在本次改动之前，这套数据只有服务层：schema、仓库、`WorkspaceService`、
/// `TaskService.assignProject` 与任务详情页的"新建项目并归属"都已完成并有测试，
/// 但**没有任何界面能建立一个项目之外的东西**——用户既无法修正默认建立的
/// 学业／科研／生活，也无法把别的领域标成生活，更无法归档一个不再使用的项目。
///
/// 界面直接暴露两件事的因果关系：生活标记在领域上，配额与统计的"生活"口径以它为准；
/// 项目必须挂在领域下，否则它就是没有归属的数据。
///
/// 编辑采用**行内编辑**而不是弹窗：控件始终在 widget 树里，测试可以按 `Key` 定位，
/// 不需要先弹出一个对话框再在对话框里找控件。同一时刻只允许编辑一行。
final class WorkspaceManagementPage extends StatefulWidget {
  const WorkspaceManagementPage({required this.workspace, super.key});

  final WorkspaceService workspace;

  @override
  State<WorkspaceManagementPage> createState() =>
      _WorkspaceManagementPageState();
}

final class _WorkspaceManagementPageState
    extends State<WorkspaceManagementPage> {
  final _newAreaName = TextEditingController();
  final _newProjectName = TextEditingController();
  final _editField = TextEditingController();

  List<PlannerArea> _areas = const [];
  List<PlannerProject> _projects = const [];
  bool _loading = true;
  bool _newAreaIsLife = false;
  String? _newProjectAreaId;
  String? _newProjectError;

  /// 正在改名的对象，形如 `area:<id>` 或 `project:<id>`；null 表示没有行在编辑。
  String? _editingKey;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _newAreaName.dispose();
    _newProjectName.dispose();
    _editField.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final areas = await widget.workspace.listAreas();
    final projects = await widget.workspace.listProjects();
    if (!mounted) return;
    setState(() {
      _areas = areas;
      _projects = projects;
      _loading = false;
      // 领域可能刚被改名或新建，保持选择仍然有效。
      _newProjectAreaId = areas.any((area) => area.id == _newProjectAreaId)
          ? _newProjectAreaId
          : (areas.isEmpty ? null : areas.first.id);
    });
  }

  void _report(String message) {
    showPlannerMessage(context, message: message);
  }

  Future<void> _createArea() async {
    final name = _newAreaName.text.trim();
    if (name.isEmpty) {
      _report('领域名称不能为空。');
      return;
    }
    await widget.workspace.createArea(name, isLife: _newAreaIsLife);
    _newAreaName.clear();
    await _reload();
    if (mounted) setState(() => _newAreaIsLife = false);
  }

  Future<void> _createProject() async {
    final areaId = _newProjectAreaId;
    final name = _newProjectName.text.trim();
    if (areaId == null) {
      setState(() => _newProjectError = '项目必须挂在领域下，请先建立领域。');
      return;
    }
    if (name.isEmpty) {
      setState(() => _newProjectError = '项目名称不能为空。');
      return;
    }
    await widget.workspace.createProject(name: name, areaId: areaId);
    _newProjectName.clear();
    if (mounted) setState(() => _newProjectError = null);
    await _reload();
  }

  void _startEditing(String key, String currentName) {
    _editField.text = currentName;
    setState(() => _editingKey = key);
  }

  Future<void> _commitRename(PlannerArea? area, PlannerProject? project) async {
    final name = _editField.text.trim();
    if (name.isEmpty) {
      _report('名称不能为空。');
      return;
    }
    if (area != null) {
      await widget.workspace.renameArea(area, name);
    } else if (project != null) {
      await widget.workspace.renameProject(project, name);
    }
    if (mounted) setState(() => _editingKey = null);
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final lifeAreas = _areas.where((area) => area.isLife).toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('领域与项目', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('领域是任务的长期归属；项目是领域下可选的阶段性工作。你可以指定哪些领域计入个人生活时间。'),
        const SizedBox(height: 8),
        if (lifeAreas.isEmpty)
          Card(
            key: const Key('no-life-area-warning'),
            color: Theme.of(context).colorScheme.errorContainer,
            child: const ListTile(
              leading: Icon(Icons.warning_amber),
              title: Text('尚无领域计入个人生活时间'),
              subtitle: Text('生活娱乐配额与统计的「生活」分类因此不会生效。'),
            ),
          ),
        const Divider(height: 40),
        Text('领域', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_areas.isEmpty) const Text('尚无领域。'),
        for (final area in _areas)
          _AreaRow(
            area: area,
            editing: _editingKey == 'area:${area.id}',
            editField: _editField,
            onStartRename: () => _startEditing('area:${area.id}', area.name),
            onConfirmRename: () => _commitRename(area, null),
            onCancelRename: () => setState(() => _editingKey = null),
            onToggleLife: (value) async {
              await widget.workspace.setAreaLife(area, value);
              await _reload();
            },
          ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新建领域', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('new-area-name'),
                  controller: _newAreaName,
                  decoration: const InputDecoration(
                    labelText: '领域名称',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  key: const Key('new-area-is-life'),
                  value: _newAreaIsLife,
                  onChanged: (value) => setState(() => _newAreaIsLife = value),
                  title: const Text('计入个人生活时间'),
                  subtitle: const Text('启用后，该领域会纳入生活配额与个人生活统计'),
                  contentPadding: EdgeInsets.zero,
                ),
                FilledButton(
                  key: const Key('create-area'),
                  onPressed: _createArea,
                  child: const Text('新建领域'),
                ),
              ],
            ),
          ),
        ),
        const Divider(height: 40),
        Text('项目', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        if (_projects.isEmpty) const Text('尚无项目。'),
        for (final project in _projects)
          _ProjectRow(
            project: project,
            areaName: _areaNameOf(project.areaId),
            editing: _editingKey == 'project:${project.id}',
            editField: _editField,
            onStartRename: () =>
                _startEditing('project:${project.id}', project.name),
            onConfirmRename: () => _commitRename(null, project),
            onCancelRename: () => setState(() => _editingKey = null),
            onToggleArchived: (value) async {
              await widget.workspace.archiveProject(project, archived: value);
              await _reload();
            },
          ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('新建项目', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                if (_areas.isEmpty)
                  const Text('项目必须挂在领域下：请先建立一个领域。')
                else ...[
                  DropdownButton<String>(
                    key: const Key('new-project-area'),
                    value: _newProjectAreaId,
                    isExpanded: true,
                    onChanged: (value) =>
                        setState(() => _newProjectAreaId = value),
                    items: [
                      for (final area in _areas)
                        DropdownMenuItem<String>(
                          value: area.id,
                          child: Text(area.name),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('new-project-name'),
                    controller: _newProjectName,
                    decoration: const InputDecoration(
                      labelText: '项目名称',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  if (_newProjectError != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _newProjectError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  FilledButton(
                    key: const Key('create-project'),
                    onPressed: _createProject,
                    child: const Text('新建项目'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _areaNameOf(String areaId) =>
      _areas
          .where((area) => area.id == areaId)
          .map((area) => area.name)
          .firstOrNull ??
      areaId;
}

final class _AreaRow extends StatelessWidget {
  const _AreaRow({
    required this.area,
    required this.editing,
    required this.editField,
    required this.onStartRename,
    required this.onConfirmRename,
    required this.onCancelRename,
    required this.onToggleLife,
  });

  final PlannerArea area;
  final bool editing;
  final TextEditingController editField;
  final VoidCallback onStartRename;
  final VoidCallback onConfirmRename;
  final VoidCallback onCancelRename;
  final ValueChanged<bool> onToggleLife;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: editing
                    ? TextField(
                        key: const Key('rename-field'),
                        controller: editField,
                        autofocus: true,
                        decoration: const InputDecoration(labelText: '名称'),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(area.name, key: Key('area-name-${area.id}')),
                          if (area.isLife)
                            Text(
                              '计入个人生活时间',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
              ),
              if (editing) ...[
                TextButton(
                  key: const Key('rename-confirm'),
                  onPressed: onConfirmRename,
                  child: const Text('保存'),
                ),
                TextButton(
                  key: const Key('rename-cancel'),
                  onPressed: onCancelRename,
                  child: const Text('取消'),
                ),
              ] else ...[
                Switch(
                  key: Key('area-life-${area.id}'),
                  value: area.isLife,
                  onChanged: onToggleLife,
                ),
                TextButton(
                  key: Key('area-rename-${area.id}'),
                  onPressed: onStartRename,
                  child: const Text('改名'),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}

final class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.project,
    required this.areaName,
    required this.editing,
    required this.editField,
    required this.onStartRename,
    required this.onConfirmRename,
    required this.onCancelRename,
    required this.onToggleArchived,
  });

  final PlannerProject project;
  final String areaName;
  final bool editing;
  final TextEditingController editField;
  final VoidCallback onStartRename;
  final VoidCallback onConfirmRename;
  final VoidCallback onCancelRename;
  final ValueChanged<bool> onToggleArchived;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: editing
                ? TextField(
                    key: const Key('rename-field'),
                    controller: editField,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: '名称'),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        key: Key('project-name-${project.id}'),
                      ),
                      Text(
                        project.isArchived ? '$areaName · 已归档' : areaName,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
          ),
          if (editing) ...[
            TextButton(
              key: const Key('rename-confirm'),
              onPressed: onConfirmRename,
              child: const Text('保存'),
            ),
            TextButton(
              key: const Key('rename-cancel'),
              onPressed: onCancelRename,
              child: const Text('取消'),
            ),
          ] else ...[
            TextButton(
              key: Key('project-rename-${project.id}'),
              onPressed: onStartRename,
              child: const Text('改名'),
            ),
            TextButton(
              key: Key('project-archive-${project.id}'),
              onPressed: () => onToggleArchived(!project.isArchived),
              child: Text(project.isArchived ? '取消归档' : '归档'),
            ),
          ],
        ],
      ),
    ),
  );
}
