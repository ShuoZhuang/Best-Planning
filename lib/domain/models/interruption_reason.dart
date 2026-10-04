/// 一次专注被打断的**原因**（FR-STAT-06 的"常见中断"）。
///
/// **为什么需要它，以及这份取值表是从哪来的**：规格要求统计页展示"常见中断"，但**没有任何
/// 一条 FR 定义过"中断"是什么、也没有任何一条要求采集它**（这一点在 §13.0 的 W5 行里查成了
/// 证据，而不是判断）。上一轮按**默认选定**把口径写定为"专注计时里暂停即记一次中断"，但
/// 那次只做到"有一种 code"，因此"常见中断"实际上只能显示"专注中暂停"一个词——**那不叫
/// 分类**。
///
/// 本枚举是那条口径的**延续**：把"为什么暂停"做成固定的几档，让统计里的"常见中断"能真的排出一个
/// 分布。取值刻意取得**少而中性**：多一档就多一份替用户定义意思的风险，而这一层本来就没有需求依据。
///
/// **2026-10-04 产品侧确认：就用这五档**（他人打断／消息或通知／自己分心／主动休息／其它原因），
/// 标签与界面顺序不变。仍未明确确认、按默认保留的两条是"中断即专注中的一次暂停"与"不填原因仍计一次"
/// （见规格 §8.9）。
///
/// **标签即事件 code**：统计页把 code 直接显示给用户，因此这里存的是中文标签而不是枚举名
/// （与 `replan:`／`suggestion:` 两处同一约定）。用户没有选择原因时仍记原来的
/// `中性标签`（`neutralLabel`），因此这次改动**不会让中断计数变少**。
enum InterruptionReason {
  /// 别人来找。
  interruptedByOthers,

  /// 消息或通知。
  message,

  /// 自己分心（走神、去刷别的）。
  selfDistraction,

  /// 主动休息一下。
  break_,

  /// 以上都不是。
  other;

  /// 用户没有选择原因时使用的标签（也是这次改动之前唯一存在的那一个）。
  static const String neutralLabel = '专注中暂停';

  String get label => switch (this) {
    InterruptionReason.interruptedByOthers => '他人打断',
    InterruptionReason.message => '消息或通知',
    InterruptionReason.selfDistraction => '自己分心',
    InterruptionReason.break_ => '主动休息',
    InterruptionReason.other => '其它原因',
  };

  /// 界面上给出的全部可选原因。顺序即界面顺序：从"外部原因"到"内部原因"，
  /// 因为"被打断"通常不是用户的自主选择，而用户更可能想少点几下就选中它。
  static const List<InterruptionReason> choices = [
    InterruptionReason.interruptedByOthers,
    InterruptionReason.message,
    InterruptionReason.selfDistraction,
    InterruptionReason.break_,
    InterruptionReason.other,
  ];
}
