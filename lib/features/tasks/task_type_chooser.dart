import 'package:flutter/material.dart';

/// 新建入口的四类去向（路线图 §3.3、§11 Task 7 Step 1；分组见设计规范 §7.1）。
///
/// **1.8.0 的变化**：`protectedTime` 不再通向 `/settings/rules`。设置页负责的是午餐、
/// 晚餐、固定休息这类**长期默认规则**，它表达不了"某天 14:00–15:00 不安排"，也表达不了
/// "每周二自定义保护时间"（§2.8）。保护时间因此成为**日历里的一种事项**，编辑入口在
/// `/calendar/protected/new`。
enum PlannerNewItemKind {
  /// 普通任务：`/tasks/new/task`。
  task,

  /// 周期目标：`/tasks/recurring/new`。
  recurringGoal,

  /// 固定日程：`/calendar/new`。
  fixedEvent,

  /// 保护时间：`/calendar/protected/new`。
  protectedTime,
}

/// 选择器里的两个分组（规范 §7.1）："这两个都是要花时间的"与"这两个都是要占时间的"，
/// 分成两组之后用户不必先理解应用内部的模块划分就能选对。
enum PlannerNewItemGroup {
  /// 任务：普通任务、周期目标。
  task('任务'),

  /// 时间占用：固定日程、保护时间。
  timeOccupancy('时间占用');

  const PlannerNewItemGroup(this.title);

  final String title;
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
    this.onBack,
    super.key,
  });

  /// 用户选了某一类。
  final void Function(PlannerNewItemKind kind) onSelect;

  /// 某一类是否有落地页。为 `null` 表示**四类都可用**（默认）。
  ///
  /// 返回 `false` 的那一类不渲染：一个"点进去说没装"的入口比没有入口更差。
  final bool Function(PlannerNewItemKind kind)? isAvailable;

  /// 页面底部的「返回」按钮是否存在。
  ///
  /// **1.8.0 起它不再承担"返回"这个动作的主要职责**：分组之后四张卡把内容撑得比
  /// 一屏高，底部的返回按钮会落到视口外——一个必须滚动才能找到的返回，等于键盘用户
  /// （Tab 到它之前先要走过四张卡）和 720 高窗口上的用户都很难用。
  /// 因此真实返回动作交给顶部标题旁的 [onBack]（与路由的返回按钮同一位置），
  /// 这个参数只保留"页面里还有一个返回入口"这一层含义，供既有调用点继续使用。
  final VoidCallback? onCancel;

  /// 标题旁的返回按钮。为 `null` 时不渲染。
  ///
  /// 与外壳顶部栏的返回按钮**同一条约定**：位置固定、始终可达、有 tooltip 与语义标签。
  final VoidCallback? onBack;

  static const _options = <PlannerNewItemKind, _OptionSpec>{
    PlannerNewItemKind.task: _OptionSpec(
      title: '普通任务',
      description: '一次做完的一件事。填标题、时长与归属即可。',
      icon: Icons.check_box_outlined,
      cardKey: 'new-type-task',
      group: PlannerNewItemGroup.task,
    ),
    PlannerNewItemKind.recurringGoal: _OptionSpec(
      title: '周期目标',
      description: '每周完成固定时长，具体做在哪天由排程决定。例如每周英语 180 分钟。',
      icon: Icons.repeat_rounded,
      cardKey: 'new-type-recurring',
      group: PlannerNewItemGroup.task,
    ),
    PlannerNewItemKind.fixedEvent: _OptionSpec(
      title: '固定日程',
      description: '时间钉死的安排，例如每周三上午的课。',
      icon: Icons.event_outlined,
      cardKey: 'new-type-fixed-event',
      group: PlannerNewItemGroup.timeOccupancy,
    ),
    PlannerNewItemKind.protectedTime: _OptionSpec(
      title: '保护时间',
      // 两句话都要有，各自挡一类误解：
      // · "排程绝不会占用它"——保护时间是**硬禁区**，不是"尽量避开"（1.7 起就写明的承诺，
      //   `task_type_chooser_test` 有专门用例守着这句话，不能顺手删掉）；
      // · "可一次性，也可按周重复"——1.8.0 起它能在日历里自己建（规范 §9.2），
      //   而不再只是从设置页继承的一条长期规则（§2.8）。
      description: '不安排任何事情的时段，例如某天下午的两小时。可一次性，也可按周重复；排程绝不会占用它。',
      icon: Icons.shield_outlined,
      cardKey: 'new-type-protected-time',
      group: PlannerNewItemGroup.timeOccupancy,
    ),
  };

  bool _isAvailable(PlannerNewItemKind kind) => isAvailable?.call(kind) ?? true;

  /// 某个分组下**可达**的卡片。整组都不可达时组标题不渲染——否则会留下一个
  /// 只有标题、下面一片空白的组，看起来像加载失败。
  List<PlannerNewItemKind> _availableIn(PlannerNewItemGroup group) => [
    for (final entry in _options.entries)
      if (entry.value.group == group && _isAvailable(entry.key)) entry.key,
  ];

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
            // 规范 §7.1：页面标题固定为「新建事项」。
            //
            // 返回按钮与标题同一行，而不是页面底部：四张卡会把内容撑过一屏，
            // 底部的返回会落到视口外（见 [onBack] 的说明）。
            Row(
              children: [
                if (onBack case final onBack?) ...[
                  IconButton(
                    key: const Key('new-item-back'),
                    tooltip: '返回',
                    onPressed: onBack,
                    icon: const Icon(Icons.arrow_back_rounded),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    '新建事项',
                    key: const Key('new-item-title'),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '先选要做的是哪一类，再填具体内容。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            for (final group in PlannerNewItemGroup.values)
              if (_availableIn(group) case final kinds
                  when kinds.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(
                  group.title,
                  key: Key('new-item-group-${group.name}'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                for (final kind in kinds)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _OptionCard(
                      spec: _options[kind]!,
                      onTap: () => onSelect(kind),
                    ),
                  ),
              ],
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
    required this.group,
  });

  final String title;
  final String description;
  final IconData icon;
  final String cardKey;
  final PlannerNewItemGroup group;
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
