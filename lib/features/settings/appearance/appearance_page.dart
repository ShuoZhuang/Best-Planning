import 'package:flutter/material.dart';
import 'package:personal_planner/application/appearance_service.dart';
import 'package:personal_planner/design/planner_theme.dart';
import 'package:personal_planner/design/planner_snack_bar.dart';

final class AppearancePage extends StatelessWidget {
  const AppearancePage({required this.service, super.key});

  final AppearanceService service;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('外观与材质')),
    body: AnimatedBuilder(
      animation: service,
      builder: (context, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Text('选择界面材质', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 6),
              const Text('切换会立即生效并保存在本机。极致版光感最强、性能开销也最高；性能较弱时可选择无玻璃效果。'),
              const SizedBox(height: 20),
              for (final mode in PlannerMaterialMode.values) ...[
                _MaterialOption(
                  mode: mode,
                  selected: service.mode == mode,
                  onTap: () => _setMode(context, mode),
                ),
                if (mode != PlannerMaterialMode.values.last)
                  const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _setMode(BuildContext context, PlannerMaterialMode mode) async {
    try {
      await service.setMode(mode);
    } catch (_) {
      if (!context.mounted) return;
      showPlannerMessage(context, message: '外观设置多次保存失败，已恢复原来的选择；详情已写入诊断日志');
    }
  }
}

final class _MaterialOption extends StatelessWidget {
  const _MaterialOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final PlannerMaterialMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final details = _details(mode);
    final preview = PlannerGlassTheme.forMode(mode);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('glass-mode-${mode.storedValue}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              _Preview(tokens: preview),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      details.$1,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(details.$2),
                    const SizedBox(height: 7),
                    Text(
                      details.$3,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class _Preview extends StatelessWidget {
  const _Preview({required this.tokens});

  final PlannerGlassTheme tokens;

  @override
  Widget build(BuildContext context) => Container(
    width: 116,
    height: 78,
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xff173a60), Color(0xff0c1522)],
      ),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        height: 43,
        decoration: BoxDecoration(
          gradient: tokens.mode == PlannerMaterialMode.off
              ? null
              : LinearGradient(
                  colors: [tokens.surfaceHighlight, tokens.surface],
                ),
          color: tokens.mode == PlannerMaterialMode.off
              ? PlannerPalette.surface
              : null,
          border: Border.all(
            color: tokens.mode == PlannerMaterialMode.off
                ? PlannerPalette.outline
                : tokens.border,
          ),
          borderRadius: BorderRadius.circular(8),
          boxShadow: tokens.mode == PlannerMaterialMode.off
              ? null
              : [
                  BoxShadow(
                    color: tokens.shadow,
                    blurRadius: tokens.shadowBlur / 2,
                    offset: const Offset(0, 5),
                  ),
                ],
        ),
        child: const Row(
          children: [
            SizedBox(width: 8),
            CircleAvatar(radius: 5, backgroundColor: PlannerPalette.accent),
            SizedBox(width: 7),
            Expanded(child: Divider()),
            SizedBox(width: 8),
          ],
        ),
      ),
    ),
  );
}

(String, String, String) _details(PlannerMaterialMode mode) => switch (mode) {
  PlannerMaterialMode.off => ('无玻璃效果', '不透明深色表面，边界最清晰。', '性能占用最低'),
  PlannerMaterialMode.restrained => ('克制版', '柔和磨砂、细亮边与轻微环境光。', '默认推荐 · 性能占用较低'),
  PlannerMaterialMode.aggressive => (
    '激进版',
    '更明显的透明层次、模糊与悬浮深度。',
    '视觉效果更强 · 性能占用较高',
  ),
  PlannerMaterialMode.liquid => (
    '极致版',
    '高透明液态层次、双重折射亮边与随指针流动的高光。',
    '苹果风格灵感 · 性能占用最高',
  ),
};
