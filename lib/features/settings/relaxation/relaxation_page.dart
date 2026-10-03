import 'package:flutter/material.dart';

/// 临时放宽某一天的每日可移动任务上限（FR-REPLAN-07 的处理入口之一）。
///
/// **为什么是"某一天"而不是全局设置**：需求 §8.4.1 的生效优先级把"用户针对某一天或某次事件
/// 设置的临时例外"排在最高，而这一条正是那个临时例外。把每日上限直接改大是另一回事
/// （永久改规则）——需求要求的是"**临时**放宽"，即"今天例外，之后照旧"。
///
/// **为什么必须带"清除"**：C8 记录过的原缺陷就是"例外有唯一写入方却没有任何清除路径，
/// 于是用户只要预览过一次恢复方案，那一天的睡眠例外就永久生效"。这里放宽的是**硬约束**，
/// 留下一个清不掉的放宽比没有这条入口更糟，因此清除按钮与保存按钮同等重要（并排在界面上，
/// 不藏在菜单里）。
///
/// **页面不认识 `SettingsService`**：它只收发数字与布尔，读写与校验都在注入方（路由持有
/// 设置服务，也才知道时区）。这与"设置截止时间"等入口的分工一致。
final class RelaxationPage extends StatefulWidget {
  const RelaxationPage({
    required this.localDate,
    required this.loadEffectiveLimitMinutes,
    required this.loadOverrideMinutes,
    required this.onSave,
    required this.onClear,
    super.key,
  });

  /// 目标日（本地日历日）。页面把它显示出来，避免用户搞不清放宽的是哪一天。
  final DateTime localDate;

  /// 该日**当前生效**的每日上限（已含既有例外）。
  final Future<int> Function() loadEffectiveLimitMinutes;

  /// 该日被临时放宽后的上限；从未放宽过时返回 `null`。
  final Future<int?> Function() loadOverrideMinutes;

  /// 写入该日的例外。返回 `false` 表示未保存成功。
  final Future<bool> Function(int minutes) onSave;

  /// 清除该日的例外。返回 `false` 表示未清除成功。
  final Future<bool> Function() onClear;

  @override
  State<RelaxationPage> createState() => _RelaxationPageState();
}

final class _RelaxationPageState extends State<RelaxationPage> {
  final TextEditingController _minutes = TextEditingController();
  int? _effective;
  int? _override;
  String? _error;
  String? _message;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _minutes.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final effective = await widget.loadEffectiveLimitMinutes();
    final override = await widget.loadOverrideMinutes();
    if (!mounted) return;
    setState(() {
      _effective = effective;
      _override = override;
      // 预填**当前生效值**而不是"某个合理的更大值"：用户要做的通常是在它基础上加一点，
      // 从空或从 0 开始会让人先删再输。
      if (_messagesAreEmpty) _minutes.text = '$effective';
    });
  }

  bool get _messagesAreEmpty => _error == null && _message == null;

  Future<void> _save() async {
    final minutes = int.tryParse(_minutes.text.trim());
    if (minutes == null) {
      setState(() {
        _error = '请输入一个整数分钟数';
        _message = null;
      });
      return;
    }
    if (minutes <= 0) {
      // 0 等于"今天不安排任何任务"，那不是放宽而是另一种极端；要停排应当用别的手段。
      setState(() {
        _error = '放宽后的上限必须大于 0 分钟';
        _message = null;
      });
      return;
    }
    final saved = await widget.onSave(minutes);
    if (!mounted) return;
    setState(() {
      _error = saved ? null : '保存失败';
      _message = saved ? '已把这一天的上限临时放宽为 $minutes 分钟' : null;
    });
    if (saved) await _reload();
  }

  Future<void> _clear() async {
    final cleared = await widget.onClear();
    if (!mounted) return;
    setState(() {
      _error = cleared ? null : '清除失败';
      _message = cleared ? '已恢复这一天的常规上限' : null;
    });
    await _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('临时放宽每日上限')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '${widget.localDate.year} 年 ${widget.localDate.month} 月 '
              '${widget.localDate.day} 日',
              style: Theme.of(context).textTheme.titleLarge,
              key: const Key('relaxation-date'),
            ),
            const SizedBox(height: 8),
            const Text(
              '放宽只作用于这一天，之后自动回到常规上限。它放宽的是每日可移动任务上限'
              '（硬约束之一），因此不会改动你的长期规则。',
            ),
            const SizedBox(height: 16),
            Text(
              _override == null
                  ? '这一天未放宽，当前上限 ${_effective ?? '…'} 分钟。'
                  : '这一天已临时放宽为 $_override 分钟'
                        '（常规上限 ${_effective ?? '…'} 分钟）。',
              key: const Key('relaxation-status'),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('relaxation-minutes'),
              controller: _minutes,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: '放宽后的每日上限（分钟）',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const Key('relaxation-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, key: const Key('relaxation-message')),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton(
                  key: const Key('relaxation-save'),
                  onPressed: _save,
                  child: const Text('放宽这一天'),
                ),
                const SizedBox(width: 12),
                // 清除与保存并排：一个清不掉的"放宽"正是 C8 记录过的缺陷，
                // 把撤销藏进菜单会让它重新变成那种缺陷。
                OutlinedButton(
                  key: const Key('relaxation-clear'),
                  onPressed: _override == null ? null : _clear,
                  child: const Text('清除这一天的放宽'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
