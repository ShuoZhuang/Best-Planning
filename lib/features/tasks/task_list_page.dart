import 'package:flutter/material.dart';
import 'package:personal_planner/application/task_service.dart';
import 'package:personal_planner/domain/models/task.dart';
import 'package:personal_planner/features/tasks/quick_add_form.dart';

final class TaskListPage extends StatefulWidget {
  const TaskListPage({required this.service, super.key});
  final TaskService service;
  @override
  State<TaskListPage> createState() => _TaskListPageState();
}

final class _TaskListPageState extends State<TaskListPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('任务清单', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 16),
          QuickAddForm(service: widget.service),
          const SizedBox(height: 16),
          SearchBar(
            hintText: '搜索任务',
            leading: const Icon(Icons.search),
            onChanged: (value) => setState(() => _query = value.trim()),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: StreamBuilder<List<PlannerTask>>(
              stream: widget.service.watchOpenTasks(),
              builder: (context, snapshot) {
                final tasks = (snapshot.data ?? const <PlannerTask>[])
                    .where(
                      (task) => task.title.toLowerCase().contains(
                        _query.toLowerCase(),
                      ),
                    )
                    .toList();
                if (tasks.isEmpty) return const Center(child: Text('暂无匹配任务'));
                return ListView.builder(
                  itemCount: tasks.length,
                  itemBuilder: (context, index) {
                    final task = tasks[index];
                    return CheckboxListTile(
                      value: task.status == TaskStatus.completed,
                      title: Text(task.title),
                      subtitle: Text('预计 ${task.estimatedMinutes} 分钟'),
                      onChanged: (checked) => widget.service.changeStatus(
                        task.id,
                        checked == true
                            ? TaskStatus.completed
                            : TaskStatus.open,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
