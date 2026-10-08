// 统一的动作反馈（路线图 §11 Task 12、"Related 撤销、空状态与提示一致性"）。
//
// **这个文件解决的是一类"看不见的损失"**：用户完成了一个任务、跳过了这一次、改了本周目标、
// 暂停了一个周期目标——这四件事里，前三件都会让计划重排，而重排是不可逆的（旧版本只在
// 历史里留着）。用户点错一下，此前没有任何回头路：提示条只说"已完成"，没有撤销入口。
//
// 三件东西分开给出，因为它们的**寿命**不一样：
//
// - 短暂成功提示（`showPlannerMessage`）：读完就没用了，4 秒自动消失，带一个"撤销"动作时
//   延长到 8 秒（`plannerActionableMessageDuration`）——手要够得着那个按钮。
// - **可撤销动作**（[showUndoableAction]）：把"做了什么"与"怎么回去"放在同一条气泡里。
//   撤销本身只回调一次，且**在气泡消失后不再可点**——否则用户会对着一个已经不在的提示
//   找不到撤销。
// - **可关闭长期提示**（[PlannerPersistentBanner]）：它讲的是一个持续状态（"这项设置挡住了
//   计划生成"），不该自己消失；但关掉之后同一条不该反复冒出来，因此用 **id** 而不是
//   bool 记"关过哪一条"——新 id（新 proposal、新版本）仍然要提醒。今日页的重排提示早就是
//   这个形状（`dismissedProposalId`），这里把它抽成可复用的一件。
import 'package:flutter/material.dart';

import 'planner_snack_bar.dart';

/// 一次可撤销动作：先做，再给一条带"撤销"的成功提示。
///
/// [undo] 只在用户真的点了"撤销"时被调用一次。
///
/// **为什么用 `onUndo` 而不是自己把 [action] 做完就算**：撤销的语义每个调用点都不一样
/// （完成 → 改回未完成；跳过 → 清掉 pendingSkips 并重排；改目标 → 写回旧值），
/// 这一层不该假装知道。它只负责**把入口稳定地摆在用户面前**。
void showUndoableAction(
  BuildContext context, {
  required String message,
  required VoidCallback onUndo,
  String undoLabel = '撤销',
}) {
  var undone = false;
  showPlannerMessage(
    context,
    message: message,
    // 动作存在时 `plannerSnackBar` 会自己把时长延长到
    // `plannerActionableMessageDuration`，这里不重复指定。
    action: SnackBarAction(
      label: undoLabel,
      onPressed: () {
        // **只允许撤销一次**：连点两下会把"改回未完成"执行两遍，而第二次是在第一次的结果
        // 上再改一次——对状态类操作通常无害，对写入类操作（写回旧目标分钟）会多写一次。
        if (undone) return;
        undone = true;
        onUndo();
      },
    ),
  );
}

/// 一条**长期**提示的骨架：图标 + 标题 + 说明 + 可选的主动作 + 关闭按钮。
///
/// 与 `showPlannerMessage` 的分工：那个是"刚发生了什么"，这个是"现在是什么状态"。
/// 状态不会因为 4 秒过去而消失，因此它**不自动关闭**；但用户可以主动关掉。
///
/// 可访问性（§11 Task 12 Step 4）：
/// - 关闭按钮有 `tooltip` 与语义标签，键盘可以聚焦并触发；
/// - 整条提示是 `liveRegion`，读屏会在它出现时播报状态变化；
/// - 它是普通文档流里的一块（不是 `Overlay`），因此**不会盖住底部内容**——
///   页面滚动时会跟着滚走，而不是浮在那里挡住最后一行。
final class PlannerPersistentBanner extends StatelessWidget {
  const PlannerPersistentBanner({
    required this.bannerId,
    required this.title,
    this.message,
    this.icon = Icons.info_outline,
    this.primaryAction,
    this.primaryActionLabel,
    this.onDismiss,
    this.dismissTooltip = '不再显示这条提示',
    super.key,
  });

  /// 这条提示的稳定标识。**用 id 而不是 bool 记"关过"**：换了新内容（新的提案、
  /// 新的版本）就该重新提醒，而用 bool 会让用户永久错过后续的每一条。
  final String bannerId;

  final String title;
  final String? message;
  final IconData icon;

  final VoidCallback? primaryAction;
  final String? primaryActionLabel;

  /// 为空时不显示关闭按钮（那种提示不该被关掉）。
  final VoidCallback? onDismiss;

  final String dismissTooltip;

  @override
  Widget build(BuildContext context) {
    final action = primaryAction;
    final label = primaryActionLabel;
    return Semantics(
      // `liveRegion` 让读屏在它出现时主动播报，而不是等用户自己撞上去。
      liveRegion: true,
      container: true,
      // **key 放在 `Semantics` 上，而不是里面的 `Card` 上**：`liveRegion` 是这一条的语义，
      // 让 key 与它在同一个节点上，"这条提示里有 liveRegion"才是一条能写的断言——
      // key 放在 Card 上时，`find.descendant(of: byKey(...), matching: ...)` 会恒不命中，
      // 因为 `Semantics` 是 Card 的先辈而不是后代（第一版就是这么写错的）。
      key: Key('planner-banner-$bannerId'),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    if (message case final message?) ...[
                      const SizedBox(height: 4),
                      Text(
                        message,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (action != null && label != null) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          key: Key('planner-banner-action-$bannerId'),
                          onPressed: action,
                          child: Text(label),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onDismiss case final onDismiss?)
                IconButton(
                  key: Key('planner-banner-dismiss-$bannerId'),
                  // tooltip 同时是语义标签：读屏念出的是"不再显示这条提示"，
                  // 而不是一个没有名字的图标按钮。
                  tooltip: dismissTooltip,
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close_rounded, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 记住"用户关过哪几条长期提示"。
///
/// **只记 id，不记"是否显示"**：显示与否由内容决定（有新 proposal 就有新 id），
/// 关过只影响"这一条还提不提醒"。因此这个存储只增不减，也不需要清理策略——
/// 一个会话里能关掉的条数是手掌数得过来的。
///
/// **为什么不用 `Set<String>` 而做一个类**：调用点需要一个"关了之后还要能重建界面"的
/// 可观察对象。页面把自己的 `dismissedBannerIds` 传进来即可，测试也能直接构造它。
final class DismissedBannerStore {
  DismissedBannerStore([Iterable<String> initial = const []])
    : _ids = {...initial};

  final Set<String> _ids;

  bool contains(String bannerId) => _ids.contains(bannerId);

  /// 记下"这条被关掉了"。返回是否是**新的**关闭（重复关同一条返回 false），
  /// 调用方据此决定要不要重建界面。
  bool dismiss(String bannerId) => _ids.add(bannerId);

  Set<String> get ids => {..._ids};
}
