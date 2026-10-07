import 'package:flutter/foundation.dart';

/// 新手教程的一步：一张**真实界面截图** + 标题 + 说明 +（可选）要点。
///
/// 用户 2026-10-07 的要求是"做一个软件新手教程出来，这样用户第一次使用的时候可以跟着图片&
/// 其他引导来走一遍软件的功能"。因此这里的图**不是示意图**，而是从真实运行窗口截下来的
/// （用 `.tooling/capture-planner.ps1` 在发布构建上采集，见台账里"教程配图"那一段）。
@immutable
final class TutorialStep {
  const TutorialStep({
    required this.title,
    required this.body,
    this.assetPath,
    this.bullets = const [],
  });

  final String title;

  /// 一到两句说明：这一步在讲什么、用户能在这里做什么。
  final String body;

  /// `assets/tutorial/` 下的截图。为空时这一页不显示图（用于纯开场/收尾的文字页）。
  final String? assetPath;

  /// 要点清单。**刻意少而具体**：每一步最多三条，写"能做什么"，不写"这个页面很强大"。
  final List<String> bullets;
}

/// 教程的步骤。顺序即用户实际的使用顺序：先看每天从哪儿开始，再看任务、日历、领域、统计、设置。
///
/// **改这个列表要同时改 `assets/tutorial/` 里的图**：图是照当时的界面截的，界面改了图就旧了。
/// 步骤数变化不需要动别处——页面用的是 `tutorialSteps.length`。
const List<TutorialStep> tutorialSteps = [
  TutorialStep(
    title: '欢迎使用智能日程',
    body:
        '这个应用只做一件事：把你想做的事排进你能用的时间里。'
        '下面用六张真实界面截图带你走一遍，大约两分钟。',
    bullets: ['右上角的「生成计划」是每天的起点', '侧边栏六项就是全部功能', '随时可以在「设置 → 新手教程」重看'],
  ),
  TutorialStep(
    title: '今日安排',
    body: '每天从这里开始。左侧时间轴按时间顺序列出今天的固定日程、保护时间和已排的任务。',
    assetPath: 'assets/tutorial/01-today.png',
    bullets: ['固定日程（课表等）与保护时间不会被排任务占掉', '右边「今日容量」告诉你今天排了多少', '卡片左侧的色条是所属领域的颜色'],
  ),
  TutorialStep(
    title: '任务清单',
    body: '所有待办在这里。勾选即完成——完成后它会从清单里消失，但仍留在统计里。',
    assetPath: 'assets/tutorial/02-tasks.png',
    bullets: [
      '勾选完成后卡片会显示「已完成」标记',
      '「多选」进入批量模式，可一次改优先级或取消',
      '截止日期临近还没排上的任务会标出「已逾期」',
    ],
  ),
  TutorialStep(
    title: '七日日历',
    body:
        '横向的日期条：最左边是昨天，然后是今天起七天，今天用主色框标出。'
        '往左滑可以回看昨天，往右滑看后面几天。',
    assetPath: 'assets/tutorial/04-calendar.png',
    bullets: [
      '任务块可以拖到别的日子，放手后会问是否锁定',
      '固定日程和保护时间不能拖：它们是硬约束',
      '点某一天的标题可进入那一天的详情',
    ],
  ),
  TutorialStep(
    title: '领域与项目',
    body: '领域是任务的长期归属，也是**所有地方的颜色来源**：改了领域颜色，今日、日历、统计一起变。',
    assetPath: 'assets/tutorial/03-areas.png',
    bullets: [
      '「计入个人生活时间」决定这个领域是否算进生活配额',
      '「特殊日程颜色」管保护时间与无领域事项的配色',
      '项目挂在领域下，是可选的阶段性划分',
    ],
  ),
  TutorialStep(
    title: '统计与复盘',
    body:
        '这里回答两个问题：我规划得合不合理、我有没有好好休息。'
        '所有数字都只统计你**计划**了什么（含课表），不看"实际花了多久"。',
    assetPath: 'assets/tutorial/05-analytics.png',
    bullets: [
      '领域占比（横向）会写明"计划多少 + 固定日程多少"',
      '时间总计（纵向）对比上周、本周、本月',
      '每张图右上角可切换饼图／柱状图／条形图／折线图，选择会被记住',
      '「休息」一节给出休息时长、作息规律性与工作休息比例',
    ],
  ),
  TutorialStep(
    title: '设置与数据安全',
    body: '外观材质、规划规则、学习偏好、数据导出与备份都在这里。页面底部能看到当前软件版本号。',
    assetPath: 'assets/tutorial/06-settings.png',
    bullets: ['四档玻璃材质可即时预览', '「数据备份与恢复」会整库备份，换机时用它', '「新手教程」就在这一页，随时可以重来一遍'],
  ),
];
