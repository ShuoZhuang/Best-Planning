import 'package:personal_planner/core/time_zone.dart';
import 'package:personal_planner/domain/repositories/settings_repository.dart';

/// 首次引导的四个状态（用户 2026-10-07 定案）。
///
/// ```
/// 未开始 → 进行中 → 已完成
///                 ↘ 已跳过
/// ```
///
/// **为什么必须是四个而不是一个布尔**：用户的原话是
/// "「退出」「跳过」「完成」定义成三个不同状态"。用一个 `bool seen` 的话，
/// **退出就会冒充完成**——用户下次启动再也看不到引导，而界面上不会有任何异常提示。
enum OnboardingState {
  /// 从没开始过：启动时**直接进引导首页**。
  notStarted,

  /// 开始了但没走完：启动时问"继续引导／重新开始／暂时跳过"。
  inProgress,

  /// 走完了：不再自动弹出。
  completed,

  /// 用户主动放弃：不再自动弹出，但**从设置仍可重新打开**（进引导首页）。
  skipped,
}

/// 引导进行到哪一步 + 处于哪个状态。
final class OnboardingProgress {
  const OnboardingProgress({required this.state, this.step});

  final OnboardingState state;

  /// 步骤标识（形如 `createTask`）。仅 [OnboardingState.inProgress] 时有意义。
  ///
  /// **为什么存字符串而不是枚举**：步骤会在实现里增删，枚举会让"旧值不再存在"
  /// 变成一次读取失败；字符串不认识就当没存过（回落 null）更稳。
  final String? step;

  @override
  bool operator ==(Object other) =>
      other is OnboardingProgress && other.state == state && other.step == step;

  @override
  int get hashCode => Object.hash(state, step);

  @override
  String toString() => 'OnboardingProgress(${state.name}, step: $step)';
}

/// 引导进度的读写。
///
/// **与既有 `onboarding.schemaVersion` 是两个维度，刻意分开存**：
/// 那个整数表达的是"关键默认值确认到哪一版了"，用于**增量重问**。
/// 若把"是否走完引导"也编码进同一个整数，那么 schema 从 1 抬到 2 时，
/// 老用户会**因为新增了一个默认值而被当成"从没引导过"**——
/// 于是刚做完的引导又从头来一遍。两者各自演化，互不干扰。
final class OnboardingProgressStore {
  const OnboardingProgressStore({required this.settings});

  final SettingsRepository settings;

  /// 状态键。**带 `v2`**：与将来可能出现的第三种编码区分开，
  /// 也表明它替代不了 `onboarding.schemaVersion`（那个键原样保留）。
  static const stateKey = 'onboarding.state.v2';

  /// 步骤键。
  static const stepKey = 'onboarding.step.v2';

  /// 读当前进度。
  ///
  /// **读失败或值不认识一律回落 [OnboardingState.notStarted]**：与
  /// `WeekViewPreferenceService.load` 同一取舍——一个读不出来的偏好不该让应用打不开。
  /// 代价是那种情况下会重新引导一次，比"卡在空白页"好。
  Future<OnboardingProgress> load() async {
    final raw = await settings.read(stateKey);
    final state = switch (raw) {
      'inProgress' => OnboardingState.inProgress,
      'completed' => OnboardingState.completed,
      'skipped' => OnboardingState.skipped,
      // 含 null 与任何不认识的值。
      _ => OnboardingState.notStarted,
    };
    if (state != OnboardingState.inProgress) {
      // 非进行中的状态不该带着步骤：留着它会让"重新开始"看起来没生效。
      return OnboardingProgress(state: state);
    }
    return OnboardingProgress(state: state, step: await settings.read(stepKey));
  }

  Future<void> save(OnboardingProgress progress) async {
    await settings.write(stateKey, progress.state.name);
    final step = progress.step;
    if (step == null) {
      await settings.remove(stepKey);
    } else {
      await settings.write(stepKey, step);
    }
  }

  /// 记下"开始了，走到哪一步"。**不写 `completed`**。
  Future<void> begin({String? step}) =>
      save(OnboardingProgress(state: OnboardingState.inProgress, step: step));

  /// 更新"进行到哪一步"，状态保持进行中。
  ///
  /// 供引导各步在推进时调用：**每一步都落盘**，这样中途退出（含异常退出）
  /// 下次能接着走，而不是从第一步重来。
  Future<void> advanceTo(String step) async {
    final current = await load();
    // 已完成／已跳过之后不该被某一步的推进"拽回"进行中。
    if (current.state == OnboardingState.completed ||
        current.state == OnboardingState.skipped) {
      return;
    }
    await begin(step: step);
  }

  /// 关闭窗口／返回主界面时调用：**状态保持进行中**。
  ///
  /// 这个方法**故意什么都不改**——"退出"的语义就是"什么都没发生"。
  /// 它存在是为了让调用点有个明确的落点（并让"退出不写已完成"这件事在代码里看得见），
  /// 而不是散落成"什么都不调用"这种无法审查的形式。
  Future<void> exitWithoutCompleting() async {
    // 有意为空。见上面的说明。
  }

  /// 询问框里的「暂时跳过」：**跳过这一次**，状态仍是进行中，下次启动还会问。
  ///
  /// **它与「跳过引导」不是一回事**（用户表格里两个词都出现，必须分清）：
  /// 这个不放弃引导，只是本次先不做；[skip] 才是"以后别再自动弹了"。
  Future<void> snooze() async {
    final current = await load();
    if (current.state != OnboardingState.inProgress) return;
    // 保持 inProgress 与原步骤：**不写任何东西**就是正确行为。
  }

  /// 引导里的「跳过引导」：以后不再自动弹出。
  Future<void> skip() =>
      save(const OnboardingProgress(state: OnboardingState.skipped));

  /// 走完引导。
  Future<void> complete() =>
      save(const OnboardingProgress(state: OnboardingState.completed));

  /// 「重新开始」：只重置**引导进度**，回到第一步。
  ///
  /// **绝不触碰任务、课程或已确认计划**——那些不在 `SettingsRepository` 里，
  /// 本方法也不越界写任何别的键（有用例守着）。
  Future<void> restart() => begin();

  /// 启动时是否该问"上次的新手引导还没有完成"。
  ///
  /// 只有**进行中**才问：没开始过就直接进引导首页（没什么可"继续"的），
  /// 已完成／已跳过都不再打扰。
  Future<bool> needsResumePrompt() async =>
      (await load()).state == OnboardingState.inProgress;
}

/// 引导生成的计划的**规划窗口**（用户 2026-10-07 定案）。
///
/// 用户原话：
/// ```
/// 规划起点：今天本地 00:00
/// 规划范围：今天 + 后续 6 个自然日
/// ```
///
/// **每次进入引导都要重新调用它**，不要缓存上次的结果：用户明确要求
/// "重新打开引导时应以重新生成当日的日期为准，不能继续使用第一次进入引导时保存的旧日期"。
/// 做成纯函数（而不是某个服务上的状态）就是为了让"重算"成为唯一的用法。
///
/// **"今天"取本机时区的日历日**，不是 UTC 的今天：本项目在保护时间展开器
/// （§13.0 的 C11）与统计页都吃过 UTC 日界的亏——UTC+8 的凌晨会差一天。
///
/// **窗口是半开区间** `[start, end)`：含今天，不含第 7 天之后的那一天。
({DateTime startUtc, DateTime endUtc}) onboardingPlanWindow({
  required DateTime nowUtc,
  required TimeZoneDatabase zones,
  required String timeZoneId,
}) {
  final local = zones.toLocal(nowUtc, timeZoneId);
  // 按**日历**推进，不用 `add(Duration(days: 7))`：绝对时间加法在夏令时切换日
  // 会退回前一天 23:00，日期不变。与 `analyticsRangeForSelectedDays` 同一处教训。
  final start = DateTime(local.year, local.month, local.day);
  final end = DateTime(local.year, local.month, local.day + 7);
  return (
    startUtc: zones.localMidnightToUtc(start, timeZoneId),
    endUtc: zones.localMidnightToUtc(end, timeZoneId),
  );
}
