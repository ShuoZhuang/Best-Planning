import 'package:flutter/material.dart';
import 'package:personal_planner/application/window_behavior_service.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';
import 'package:personal_planner/domain/models/window_behavior.dart';

/// 窗口与后台：关闭主窗口时的行为。
///
/// 单独一页而不是塞进"外观与材质"：这是**行为**设置，找它的人不会去翻材质档位。
final class WindowBackgroundPage extends StatefulWidget {
  const WindowBackgroundPage({required this.windowBehavior, super.key});

  final WindowBehaviorService windowBehavior;

  @override
  State<WindowBackgroundPage> createState() => _WindowBackgroundPageState();
}

final class _WindowBackgroundPageState extends State<WindowBackgroundPage> {
  WindowCloseBehavior? _behavior;
  bool _saving = false;

  /// 原生端是否报告托盘图标可用。null 表示还没问过。
  bool? _trayAvailable;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 打开页面时就同步一次并问一次托盘可用性：托盘建不出来时，用户应该在**看到选项的同时**
    // 就知道"收进后台"不会生效，而不是等他改一次设置才被告知。
    final behavior = await widget.windowBehavior.load();
    final status = await widget.windowBehavior.pushStored();
    if (!mounted) return;
    setState(() {
      _behavior = behavior;
      _trayAvailable = status.available;
    });
  }

  Future<void> _select(WindowCloseBehavior behavior) async {
    if (_saving) return;
    setState(() => _saving = true);
    final status = await widget.windowBehavior.apply(behavior);
    if (!mounted) return;
    setState(() {
      _behavior = behavior;
      _trayAvailable = status.available;
      _saving = false;
    });
    if (!status.available) {
      showPlannerMessage(
        context,
        message: '当前环境无法使用托盘图标（${status.detail}），关闭窗口不会收进后台。',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final behavior = _behavior;
    return Scaffold(
      appBar: AppBar(title: const Text('窗口与后台')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('关闭主窗口时', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '托盘图标常驻：右键可"打开主界面"或"退出"。收进后台时排程与提醒继续运行。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (behavior == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else ...[
            // 用 SegmentedButton 而不是 RadioListTile：后者在本版 Flutter 里 groupValue /
            // onChanged 已废弃，而分段按钮是本仓库既有的单选写法（见事件编辑器）。
            SegmentedButton<WindowCloseBehavior>(
              key: const Key('close-behavior'),
              segments: [
                for (final option in WindowCloseBehavior.values)
                  ButtonSegment<WindowCloseBehavior>(
                    value: option,
                    label: Text(option.label),
                  ),
              ],
              selected: {behavior},
              onSelectionChanged: _saving
                  ? null
                  : (values) => _select(values.first),
            ),
            const SizedBox(height: 8),
            Text(
              _describe(behavior),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_trayAvailable == false) ...[
            const SizedBox(height: 12),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Padding(
                padding: EdgeInsets.all(16),
                child: Text('托盘图标未创建成功，因此"最小化到后台运行"目前不会生效。'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _describe(WindowCloseBehavior behavior) => switch (behavior) {
    WindowCloseBehavior.minimizeToTray => '窗口隐藏，程序继续在后台运行',
    WindowCloseBehavior.quit => '窗口关闭即结束程序（托盘图标随之消失）',
  };
}
