# 智能日程视觉方向确认

- 确认日期：2026-10-03
- 用户选择原话：`3`
- 选定方向：第 3 套「专注控制台 / Focus Console」
- 实现目标：以深色石墨桌面界面呈现七日容量、今日日程、当前任务、调整预览和近期截止风险；保留现有功能、路由和本地数据逻辑。

## 三版方向稿

1. `design/visual-directions/direction-1-quiet-timeline.png`
2. `design/visual-directions/direction-2-campus-studio.png`
3. `design/visual-directions/direction-3-focus-console-selected.png`（已选定）

## 视觉约束

- 石墨和炭灰表面，不使用纯黑背景。
- 暖白文字，单一克制的钴蓝强调色。
- 以时间轴、细分隔线和层级平面组织信息，避免默认 Material 卡片堆叠。
- 固定、保护、可移动和生活事项使用图标、文字与低饱和色共同表达，不依赖颜色 alone。
- 圆角规则：输入与小控件 8px，面板 12px，仅状态标签使用胶囊形。
- 动效服务于状态变化和空间连续性，尊重减少动态效果设置。
- 第一实施范围：全局主题、桌面导航、今日页与可复用视觉组件；其他页面先继承全局主题，随后按同一系统逐页深化。
