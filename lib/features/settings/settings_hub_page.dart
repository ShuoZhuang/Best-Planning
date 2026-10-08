import 'package:flutter/material.dart';
import 'package:personal_planner/design/planner_theme.dart';

/// 设置首页的分组（M8，路线图 §12「设置整理」）。
///
/// **顺序就是 §12 原文的顺序**：规划与时间 → 外观与交互 → 通知与隐私 → 数据与帮助。
/// 声明顺序即渲染顺序，因此调整顺序只改这里。
enum SettingsGroup {
  planning('规划与时间'),
  appearance('外观与交互'),
  notification('通知与隐私'),
  data('数据与帮助');

  const SettingsGroup(this.label);

  final String label;
}

/// 读取一个入口的"当前关键值"（M8，§12「设置整理」第 2 条）。
///
/// **为什么用回调而不是让页面持有服务**：与 [SettingsHubEntry.onOpen] 同一理由——
/// 这一页不认识任何服务，只负责列出来。值由组合根（路由器）从已有服务读出。
///
/// 返回 `null` 或空串表示"没有可展示的值"，此时**只显示副标题**，
/// 不显示"未设置"这类占位（那对用户没有用，与本仓库既有的"没有值就不渲染"同一口径）。
typedef SettingsValueReader = Future<String?> Function();

/// 设置入口页的一条：标题、说明、所属分组与"打开哪个子页"的动作。
///
/// 动作由路由器注入，因此这一页不认识路由，也不认识任何服务——它只负责列出来。
final class SettingsHubEntry {
  const SettingsHubEntry({
    required this.title,
    required this.subtitle,
    required this.onOpen,
    this.group = SettingsGroup.planning,
    this.currentValue,
    this.key,
  });

  final String title;
  final String subtitle;
  final VoidCallback onOpen;

  /// 这一项属于哪个分组（M8）。默认归「规划与时间」——绝大多数设置项都属于它。
  final SettingsGroup group;

  /// 当前关键值的读法（M8）。为空或读不出内容时只显示 [subtitle]。
  final SettingsValueReader? currentValue;

  final Key? key;
}

/// 设置类页面的统一入口（信息架构整理）。
///
/// 此前每加一个设置类页面就往侧边导航里塞一项：统计、偏好、设置、应用锁、导出接连追加，
/// 导航从 6 项涨到 9 项，而 W3 那行的"信息架构提醒"早已预告过这件事——把设置收成一个
/// 入口页、其下再列子页更合适。这一页就是那个入口。
///
/// **M8 的两处改进**（§12「设置整理」）：
/// 1. 按 [SettingsGroup] **分组**（此前是一个九项平铺的列表，用户要在"外观与材质""学期与
///    节次模板""导出与备份"之间自己找）；
/// 2. 每个入口展示**当前关键值**（此前副标题是静态说明，不反映任何状态；于是想确认
///    "信任自动调整到底开没开"必须点进去一项项翻——而设置页的意义恰恰是不用进去就能看到现状）。
///
/// 只渲染**实际装配好的**子页：未装配的服务不出现在列表里，因此不会留下点不动的入口；
/// **空分组整组不渲染**，不留空标题。
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
            for (final group in SettingsGroup.values)
              ..._groupSection(context, group),
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

  /// 一个分组的标题 + 它的条目。
  ///
  /// **空分组返回空列表**（整组不渲染）：未装配的服务本来就不会出现在 `entries` 里，
  /// 留一个下面什么都没有的标题只会让人以为"这一组还没加载出来"。
  List<Widget> _groupSection(BuildContext context, SettingsGroup group) {
    final groupEntries = entries
        .where((entry) => entry.group == group)
        .toList(growable: false);
    if (groupEntries.isEmpty) return const [];

    return [
      // **间距刻意收紧到 14 / 6**（M8 实测调过）。
      //
      // 第一版用的是 24 / 8，加上四个组标题，把靠后的入口整体推下去了：
      // 默认 800×600 窗口下「学习偏好」从"直接点得到"变成"必须滚动"
      // （`preferences_route_test` 因此红，报的是 tap 落在 y=626 的视口外）。
      // 真实窗口是 1280×720，但**小窗口本来就该能用**，分组是为了更好找，
      // 不该顺手把别的入口推下去。收紧后四组的分隔感仍在（标题 + 间距），
      // 但整体高度少了一截。
      const SizedBox(height: 14),
      Text(
        group.label,
        key: ValueKey('settings-group-${group.name}'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 6),
      for (final (index, entry) in groupEntries.indexed)
        Padding(
          padding: EdgeInsets.only(
            bottom: index == groupEntries.length - 1 ? 0 : 12,
          ),
          child: Card(child: _EntryTile(entry: entry)),
        ),
    ];
  }
}

/// 一条入口。
///
/// **有状态**是因为"当前值"要异步读出来（M8）：首帧先只显示副标题，
/// 读到再补上——不为了一个提示把整页卡在加载态。
final class _EntryTile extends StatefulWidget {
  const _EntryTile({required this.entry});

  final SettingsHubEntry entry;

  @override
  State<_EntryTile> createState() => _EntryTileState();
}

final class _EntryTileState extends State<_EntryTile> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _EntryTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 入口本身被换掉（例如路由器重新装配）时重新读一次。
    if (oldWidget.entry != widget.entry) _load();
  }

  /// 读当前值。
  ///
  /// **读失败不抛**：读不出当前值只是少一行提示，不该让整个设置页打不开——
  /// 与"设置写失败不崩"同一取舍（`WeekViewPreferenceService.save` 也是这样）。
  Future<void> _load() async {
    final reader = widget.entry.currentValue;
    if (reader == null) return;
    try {
      final value = await reader();
      if (!mounted) return;
      // 空串按"没有值"处理：空行会占出一段莫名其妙的空白。
      if (value == null || value.isEmpty) return;
      setState(() => _value = value);
    } on Object {
      // 保持 `_value == null`：只显示副标题。
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final value = _value;
    return ListTile(
      key: entry.key,
      minTileHeight: 64,
      title: Text(entry.title),
      subtitle: Text(entry.subtitle),
      // **当前值放右侧而不是塞进副标题**（M8）。
      //
      // 第一版把它作为副标题的第二行，结果实测把入口挤到视口外：默认 800×600 窗口下，
      // 原本能直接点到的「学习偏好」变成必须滚动才能找到（`preferences_route_test` 因此红）。
      // 真实窗口是 1280×720，但**小窗口本来就该能用**，而这个改动的本意是"更好找"，
      // 不该顺手把别的入口推下去。
      //
      // 放右侧同时更贴 §12 的意图："每个入口展示一项当前关键值"——它是一句**状态**，
      // 而副标题是一句**说明**；两者并排，用户扫一眼右列就能比较各项现状。
      // 读不出值时保持原来的 `chevron_right`，界面不会因此变样。
      trailing: value == null
          ? const Icon(Icons.chevron_right)
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 220),
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    key: entry.key == null
                        ? null
                        : ValueKey(
                            '${(entry.key! as ValueKey<String>).value}-current',
                          ),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PlannerPalette.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
      onTap: entry.onOpen,
    );
  }
}
