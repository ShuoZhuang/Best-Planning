import 'package:flutter/material.dart';

/// 新建入口的四类去向（路线图 §3.3、§11 Task 7 Step 1）。
enum PlannerNewItemKind {
  /// 普通任务：`/tasks/new/task`。
  task,

  /// 周期目标：`/tasks/recurring/new`。
  recurringGoal,

  /// 固定日程：`/calendar/new`。
  fixedEvent,

  /// 保护时间：`/settings/rules`。
  protectedTime,
}

/// 「新建」的类型选择器。
///
/// **为什么要有这一页**：此前的 `/tasks/new` 直接就是任务表单，于是"每周英语 180 分钟"
/// 只能被当成一件 180 分钟的普通任务来填——而周期目标的语义（每周重新开始、按周汇总专注、
/// 未达标不结转）与普通任务完全不同。用户要的是"四种清楚的去向"，因此这里给出四条明确
/// 命名的路，而不是在任务表单里塞一个类型下拉框——后者会让"周期目标"看起来只是任务的
/// 一个字段，而它有自己的模板、周期与历史。
///
/// **导航由路由注入**（与 `TaskEditorPage` 的 `onSaved`／`onCancel` 同一条约定）：
/// 页面不认识任何路由，也就不可能在测试里指向一个真实不存在的地址。
///
/// **某条去向不可达时那张卡不渲染**：由 `isAvailable` 回答"这一条有没有落地页"，
/// 与"不给一个点了没反应的按钮"是同一条规矩（备份、更新、导出页都是这个形状）。
final class TaskTypeChooserPage extends StatelessWidget {
  const TaskTypeChooserPage({
    required this.onSelect,
    this.isAvailable,
    this.onCancel,
    super.key,
  });

  /// 用户选了某一类。
  final void Function(PlannerNewItemKind kind) onSelect;

  /// 某一类是否有落地页。为 `null` 表示**四类都可用**（默认）。
  ///
  /// 返回 `false` 的那一类不渲染：一个"点进去说没装"的入口比没有入口更差。
  final bool Function(PlannerNewItemKind kind)? isAvailable;

  /// 返回上一页。为 `null` 时不显示返回按钮。
  final VoidCallback? onCancel;

  static const _options = <PlannerNewItemKind, _OptionSpec>{
    PlannerNewItemKind.task: _OptionSpec(
      title: '普通任务',
      description: '一次做完的一件事。填标题、时长与归属即可。',
      icon: Icons.check_box_outlined,
      cardKey: 'new-type-task',
    ),
    PlannerNewItemKind.recurringGoal: _OptionSpec(
      title: '周期目标',
      description: '每周完成固定时长，具体做在哪天由排程决定。例如每周英语 180 分钟。',
      icon: Icons.repeat_rounded,
      cardKey: 'new-type-recurring',
    ),
    PlannerNewItemKind.fixedEvent: _OptionSpec(
      title: '固定日程',
      description: '时间钉死的安排，例如每周三上午的课。',
      icon: Icons.event_outlined,
      cardKey: 'new-type-fixed-event',
    ),
    PlannerNewItemKind.protectedTime: _OptionSpec(
      title: '保护时间',
      description: '不安排任何事情的时段，例如午餐与睡眠。排程绝不会占用它。',
      icon: Icons.shield_outlined,
      cardKey: 'new-type-protected-time',
    ),
  };

  bool _isAvailable(PlannerNewItemKind kind) => isAvailable?.call(kind) ?? true;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 780),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新建', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              '先选要做的是哪一类，再填具体内容。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            for (final entry in _options.entries)
              if (_isAvailable(entry.key))
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _OptionCard(
                    spec: entry.value,
                    onTap: () => onSelect(entry.key),
                  ),
                ),
            if (onCancel != null) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const Key('new-type-cancel'),
                  onPressed: onCancel,
                  child: const Text('返回'),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

final class _OptionSpec {
  const _OptionSpec({
    required this.title,
    required this.description,
    required this.icon,
    required this.cardKey,
  });

  final String title;
  final String description;
  final IconData icon;
  final String cardKey;
}

final class _OptionCard extends StatelessWidget {
  const _OptionCard({required this.spec, required this.onTap});

  final _OptionSpec spec;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      key: Key(spec.cardKey),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(spec.icon, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    spec.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    spec.description,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    ),
  );
}
