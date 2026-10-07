import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';

/// 设置入口页的一条：标题、说明与"打开哪个子页"的动作。
///
/// 动作由路由器注入，因此这一页不认识路由，也不认识任何服务——它只负责列出来。
final class SettingsHubEntry {
  const SettingsHubEntry({
    required this.title,
    required this.subtitle,
    required this.onOpen,
    this.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback onOpen;
  final Key? key;
}

/// 设置类页面的统一入口（信息架构整理）。
///
/// 此前每加一个设置类页面就往侧边导航里塞一项：统计、偏好、设置、应用锁、导出接连追加，
/// 导航从 6 项涨到 9 项，而 W3 那行的"信息架构提醒"早已预告过这件事——把设置收成一个
/// 入口页、其下再列子页更合适。这一页就是那个入口。
///
/// 只渲染**实际装配好的**子页：未装配的服务不出现在列表里，因此不会留下点不动的入口。
final class SettingsHubPage extends StatelessWidget {
  const SettingsHubPage({required this.entries, this.versionLabel, super.key});

  final List<SettingsHubEntry> entries;

  /// 页面底部的软件版本号（形如 `1.5.0+29`）。
  ///
  /// **为什么由外面传进来**：版本常量的唯一来源是 `lib/app/backup_assembly.dart` 的 `appVersion`
  /// （`pubspec.yaml` 是数值来源，二者由 `version_consistency_test` 守着一致）。这一页不认识
  /// 版本也不需要认识——与它不认识任何服务是同一条理由，同时 widget 测试可以喂任意值。
  ///
  /// 为空时整行不渲染，而不是显示"未知版本"：那句话对用户没有任何用。
  final String? versionLabel;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('设置')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('设置', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 4),
            const Text('排程规则、学习偏好与数据安全都在这里。'),
            const SizedBox(height: 16),
            for (final (index, entry) in entries.indexed)
              Padding(
                padding: EdgeInsets.only(
                  bottom: index == entries.length - 1 ? 0 : 12,
                ),
                child: Card(
                  child: ListTile(
                    key: entry.key,
                    minTileHeight: 64,
                    title: Text(entry.title),
                    subtitle: Text(entry.subtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: entry.onOpen,
                  ),
                ),
              ),
            if (versionLabel != null) ...[
              const SizedBox(height: 28),
              Center(
                child: Text(
                  '软件版本 $versionLabel',
                  key: const Key('settings-version-label'),
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: PlannerPalette.textMuted),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
