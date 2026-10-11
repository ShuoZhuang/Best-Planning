import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:personal_planner/design/planner_pickers.dart';

/// 只读、可点击的日期字段（1.8.0，设计规范 §8.1）。
///
/// **为什么不用文本框**：此前的固定日程编辑器让用户手输 `YYYY-MM-DD`（§2.7）。那有两个问题：
/// 一是**格式成了用户的负担**——他得记住并敲对那串字符；二是**非法输入要等到保存才知道**，
/// 而正确做法是根本不给输入非法值的可能。
///
/// **不是 `TextFormField(readOnly: true)`**：那样只能"点开选择器"，键盘用户按 Enter／Space
/// 没有反应，而规范 §9 要求所有新入口支持键盘操作。这里用 `InkWell` + `Focus` 显式处理
/// `Enter` 与 `Space`，并用可聚焦的行来承载语义标签。
///
/// **日期值以 `DateTime` 暴露，不以文本暴露**（计划 Task 6 的 Interfaces）：
/// 调用方拿到的一定是一个真正的日期，不需要再解析一遍——"格式化只用于显示"。
final class PlannerDateField extends StatelessWidget {
  const PlannerDateField({
    required this.value,
    required this.onChanged,
    this.label = '日期',
    this.firstDate,
    this.lastDate,
    this.enabled = true,
    this.errorText,
    this.boxKey,
    super.key,
  });

  /// 当前值（只有年月日有意义）。
  final DateTime value;
  final ValueChanged<DateTime> onChanged;
  final String label;

  /// 可选范围。为空时给一个足够宽的默认区间（1900–2100），而不是让调用方到处填。
  final DateTime? firstDate;
  final DateTime? lastDate;
  final bool enabled;
  final String? errorText;

  /// 框本身（可点的那块）的 key。
  ///
  /// 与 [key] 分开：`key` 落在字段整体（含标签）上，`boxKey` 落在**点击目标**上。
  /// 合成 `<字段 key>-box` 那种约定会依赖调用方传进来的 key 的具体类型与值，
  /// 一旦有人传 `Key('…')` 而不是 `ValueKey<String>('…')` 就悄悄失效——本任务里
  /// 正是这么踩了一次（测试报 `Bad state: No element`）。显式给一个 key 更笨但不会错。
  final Key? boxKey;

  /// 显示格式。**只用于显示**：本项目是中文界面，用 `yyyy 年 M 月 d 日` 比 ISO 更像人话，
  /// 而值本身仍是 `DateTime`。
  String get displayText => DateFormat('yyyy 年 M 月 d 日').format(value);

  Future<void> _pick(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: firstDate ?? DateTime(1900),
      lastDate: lastDate ?? DateTime(2100),
      // **必须传**：不传则选择器用 Material 浅色默认值，与本应用的深色外壳拼在一起
      // 像两个程序，且"取消／确定"按钮在深色面板上几乎看不见（见 planner_pickers.dart）。
      builder: plannerPickerBuilder,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return _PlannerTappableField(
      boxKey: boxKey,
      label: label,
      displayText: displayText,
      // 语义标签带上当前值：屏幕阅读器用户需要知道"现在填的是什么"，
      // 而不是只知道"这是一个日期字段"。
      semanticsValue: displayText,
      icon: Icons.calendar_today_outlined,
      enabled: enabled,
      errorText: errorText,
      onActivate: () => _pick(context),
    );
  }
}

/// 只读、可点击的时间字段（1.8.0，设计规范 §8.1）。
///
/// 与 [PlannerDateField] 同一形状，只是走 `showTimePicker` 并暴露 `TimeOfDay`。
/// **`TimeOfDay` 而不是 `(int hour, int minute)`**：那是 Flutter 自己给"一天里的一个时刻"
/// 的类型，转换成 `LocalTimeRange` 需要的分钟数只需要一次 `hour * 60 + minute`。
final class PlannerTimeField extends StatelessWidget {
  const PlannerTimeField({
    required this.value,
    required this.onChanged,
    this.label = '时间',
    this.enabled = true,
    this.errorText,
    this.boxKey,
    super.key,
  });

  final TimeOfDay value;
  final ValueChanged<TimeOfDay> onChanged;
  final String label;
  final bool enabled;
  final String? errorText;

  /// 框本身（可点的那块）的 key。与 [PlannerDateField.boxKey] 同一理由与同一条约定。
  final Key? boxKey;

  /// `HH:mm`，24 小时制。**刻意不用 `MaterialLocalizations.formatTimeOfDay`**：
  /// 那个会跟着系统偏好变成 `下午 2:00` 或 `2:00 PM`，而本应用的排程与保护时间到处都用
  /// `HH:mm`（设置页、时间轴刻度、卡片文字）。显示口径不一致比"本地化不彻底"更糟。
  String get displayText =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';

  Future<void> _pick(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: value,
      builder: plannerPickerBuilder,
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return _PlannerTappableField(
      boxKey: boxKey,
      label: label,
      displayText: displayText,
      semanticsValue: displayText,
      icon: Icons.schedule_outlined,
      enabled: enabled,
      errorText: errorText,
      onActivate: () => _pick(context),
    );
  }
}

/// 一段"开始 → 结束"的本地时间，带**时长联动**（设计规范 §8.2）。
///
/// 三条规则，按用户实际会做的动作排：
///
/// 1. **改开始时间时保持原时长**，并联动结束时间。用户把会议从 14:00 挪到 15:00，
///    他想要的是"整段后移一小时"，不是"开始变了、结束没变"（那会静默改短时长）。
/// 2. **用户手动改过结束时间之后**，再改开始时间**只在新的结束不晚于开始时**才自动修正。
///    把用户刚亲手设的结束时间无条件覆盖掉，等于把他那一次编辑扔掉。
/// 3. **结束早于或等于开始时**必须明确处理（跨到次日 / 重选），**不做静默猜测**。
///    这一条由 [crossesMidnight] 与各页自己的校验承担：这里只如实报出"结束不晚于开始"，
///    由界面去问用户，而不是替他决定这是跨日还是填错了。
final class LocalDateRangeController extends ChangeNotifier {
  LocalDateRangeController({
    required DateTime startDate,
    required this.startTime,
    required DateTime endDate,
    required this.endTime,
  }) : _startDate = _dateOnly(startDate),
       _endDate = _dateOnly(endDate);

  DateTime _startDate;
  TimeOfDay startTime;
  DateTime _endDate;
  TimeOfDay endTime;

  /// 用户是否**亲手**改过结束时间。规则 2 的判据。
  bool _endTouched = false;

  DateTime get startDate => _startDate;
  DateTime get endDate => _endDate;

  /// 用户是否手动设过结束时间（界面可以据此调整提示语气）。
  bool get endTouched => _endTouched;

  /// 结束是否落在开始之前或与开始同一时刻。
  bool get endsNotAfterStart => !endLocal.isAfter(startLocal);

  /// 结束是否跨到了次日。**只看日期**：结束日期晚于开始日期就是跨日，
  /// 这与"结束钟点比开始早"是两件事（22:00 → 次日 01:00 与 22:00 → 当天 01:00 不同）。
  bool get crossesMidnight => _endDate.isAfter(_startDate);

  /// 开始与结束的本地墙上时间（只有年月日与时分有意义）。
  DateTime get startLocal => DateTime(
    _startDate.year,
    _startDate.month,
    _startDate.day,
    startTime.hour,
    startTime.minute,
  );

  DateTime get endLocal => DateTime(
    _endDate.year,
    _endDate.month,
    _endDate.day,
    endTime.hour,
    endTime.minute,
  );

  int get durationMinutes => endLocal.difference(startLocal).inMinutes;

  void setStartDate(DateTime value) {
    _startDate = _dateOnly(value);
    // 日期后移而结束日期落在开始之前时，把结束日期一起搬过去：
    // 用户改的是"哪一天"，不是"结束比开始早"。
    if (_endDate.isBefore(_startDate)) _endDate = _startDate;
    notifyListeners();
  }

  void setEndDate(DateTime value) {
    _endDate = _dateOnly(value);
    _endTouched = true;
    notifyListeners();
  }

  /// 改开始时间。规则 1 与规则 2 都在这里。
  void setStartTime(TimeOfDay value) {
    final previousStart = startLocal;
    final previousDuration = endLocal.difference(previousStart);
    startTime = value;

    // 规则 1：没手动改过结束 ⇒ 保持原时长（按本地墙上时间平移，不按 UTC 时长——
    // 跨夏令时的那一天，"时长"在墙上时间与经过时间之间本来就不同，而用户设的是墙上时间）。
    if (!_endTouched) {
      final shifted = startLocal.add(previousDuration);
      _endDate = _dateOnly(shifted);
      endTime = TimeOfDay(hour: shifted.hour, minute: shifted.minute);
      // 保持原时长之后结束仍然不晚于开始：说明"原时长"来自一个本来就非法的区间
      // （用户先手动把结束设到开始之前，再改开始时间）。此时**不能继续沿用那个非法时长**
      // ——那只会把错误原样搬到一个新的位置。退化成"开场后一分钟"这一个合法最小片段，
      // 界面再按 [endsNotAfterStart] 的判定去问用户要不要跨日或重选。
      if (endsNotAfterStart) {
        final fallback = startLocal.add(const Duration(minutes: 1));
        _endDate = _dateOnly(fallback);
        endTime = TimeOfDay(hour: fallback.hour, minute: fallback.minute);
      }
      notifyListeners();
      return;
    }

    // 规则 2：**用户已经手动设过结束时间**，只在新的结束不晚于开始时才自动修正。
    // 修正方式与规则 1 一致（按原时长后移），因为"结束时移"是这里唯一不改变用户意图的读法；
    // 真正的跨日选择由界面按 [endsNotAfterStart] 去问用户。
    if (endsNotAfterStart) {
      final shifted = startLocal.add(previousDuration);
      _endDate = _dateOnly(shifted);
      endTime = TimeOfDay(hour: shifted.hour, minute: shifted.minute);
    }
    notifyListeners();
  }

  /// 改结束时间。会置上"用户动过"的标记——这正是规则 2 的前提。
  void setEndTime(TimeOfDay value) {
    endTime = value;
    _endTouched = true;
    notifyListeners();
  }

  /// 把结束日期与开始日期对齐（"跨到次日"的反向操作：用户选了"不是跨日"）。
  void alignEndDateToStart() {
    _endDate = _startDate;
    notifyListeners();
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

/// 两个字段共用的外壳：只读文本 + 图标 + 键盘可达的点击区。
///
/// **刻意不接受 `key`**：两个公开字段把 `key` 用在自己身上，如果这里再透传一次，
/// 同一棵树里就会出现两个同 key 的 `Widget`——`find.byKey` 因此变得有歧义，
/// 而 `tap()` 会直接报 "ambiguously found multiple matching widgets"。
///
/// **关于规范 §8.1 的"日期、时间仍可复制"**：这一条**没有完全达成**，是刻意的取舍。
/// 让文本可选中需要在字段里放 `SelectableText` 或 `SelectionArea`，而两者都会抢走
/// 或遮挡键盘激活（四条走法都试过，见 `build` 里的清单）——"可复制"换来的是
/// "键盘用户按 Enter 没反应"。规范 §9 把键盘操作列为**硬要求**，而可复制是便利；
/// 两者冲突时保留键盘可用性。用户仍可用选择器改值、用窗口截图或手工誊写取得该时刻。
final class _PlannerTappableField extends StatelessWidget {
  const _PlannerTappableField({
    required this.label,
    required this.displayText,
    required this.semanticsValue,
    required this.icon,
    required this.enabled,
    required this.onActivate,
    this.boxKey,
    this.errorText,
  });

  final String label;
  final String displayText;
  final String semanticsValue;
  final IconData icon;
  final bool enabled;
  final VoidCallback onActivate;

  /// 框本身（可点的那块）的 key，供测试与无障碍工具定位点击目标。
  final Key? boxKey;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final borderColor = errorText == null
        ? theme.dividerColor
        : theme.colorScheme.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // **用 `TextButton` 而不是 `InkWell` 包一个只读文本**。
        //
        // 四条路都试过，前三条不行，全部记在这里免得重走：
        // 1. `InkWell` + `SelectableText`：`SelectableText` 在手势竞技场里赢过 `InkWell`，
        //    于是"点日期文字"打不开选择器。
        // 2. `InkWell` + `SelectionArea`：`SelectionArea` 装的是 `SelectableRegion`，
        //    它自己带一个 `FocusNode` 并会抢走焦点；键盘用户 Tab 过来后焦点落在选区上，
        //    Enter 什么都不做。
        // 3. `TextButton` + `SelectionArea`（外层）：同上——`SelectableRegion` 仍然抢焦点
        //    （实测 `primaryFocus` 的 `debugLabel` 就是 `SelectableRegion`）。
        // 4. **本条：`TextButton` + 普通 `Text`，不套 `SelectionArea`。**
        //
        // `TextButton` 一次给出点击、焦点、Enter／Space 激活与按钮语义，这是**键盘可用性**
        // 换来的。代价写在下面，是刻意的取舍。
        TextButton(
          // 框本身的可寻址 key（`<字段 key>-box`）：字段的 key 在外层 `Column` 上，
          // 而点击目标是框。没有这个 key，测试只能"从外层 key 往下找 TextButton"，
          // 那种写法在字段被别的东西包一层时就会失效。
          key: boxKey,
          onPressed: enabled ? onActivate : null,
          style: TextButton.styleFrom(
            // 44×44 以上点击区域（规范 §9）。
            minimumSize: const Size.fromHeight(44),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            backgroundColor: Colors.transparent,
            foregroundColor: theme.colorScheme.onSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: borderColor),
            ),
            alignment: Alignment.centerLeft,
            textStyle: theme.textTheme.bodyMedium,
          ),
          // **标签与值都在按钮里，用 `Column(mainAxisSize: min)`**：此前标签在按钮**外面**、
          // 提示在下面，三段加起来比 `Wrap` 单元格高 2 像素（`RenderFlex overflowed by 2.0
          // pixels`）。把标签挪进来并让列取最小高度，是消除那个溢出的**结构性**办法，
          // 而不是调一个刚好够用的魔法数字。
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  Icon(icon, size: 16),
                ],
              ),
              const SizedBox(height: 2),
              Semantics(
                // 值写进语义，标签写"字段名 + 当前值"：只读字段没有输入框那条语义通路，
                // 因此这两样必须显式给出来，否则屏幕阅读器只会念出一个孤零零的字段名。
                //
                // **不写 `textField: true`**：那会把这一格宣告成可输入的文本框，而它按
                // 设计恰恰不能输入（规范 §8.1）。语义说的必须是事实。
                label: '$label，$semanticsValue',
                button: true,
                enabled: enabled,
                // `container: false`：语义附在按钮自己的节点上，不另起一层——
                // 多一层会让"焦点控件的语义标签"取到空串（实测过）。
                container: false,
                child: Text(
                  displayText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
        if (errorText case final message?) ...[
          const SizedBox(height: 4),
          Text(message, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 4),
        Text('点击选择，或按 Enter / 空格打开选择器', style: theme.textTheme.bodySmall),
      ],
    );
  }
}
