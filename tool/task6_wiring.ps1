# 一键接线 / 一键回退（Task 6 排查用）
#
# 为什么要有这个脚本：接线涉及 schedule_engine.dart 与 day_allocation.dart 的
# 十几处协同改动，手抄十几次既慢又容易漏。把它固定下来，才能低成本地
# "接线 → 跑一条用例 → 回退"反复实验。
#
#   pwsh -File tool/task6_wiring.ps1 -Apply      # 接线
#   pwsh -File tool/task6_wiring.ps1 -Revert     # 回退到 HEAD
param([switch]$Apply, [switch]$Revert)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if ($Revert) {
  git checkout -- lib/scheduling/schedule_engine.dart lib/scheduling/day_allocation.dart
  Write-Output '已回退接线（lib 两文件恢复到 HEAD）'
  exit 0
}

if (-not $Apply) { Write-Output '请指定 -Apply 或 -Revert'; exit 1 }

$engine = 'lib/scheduling/schedule_engine.dart'
$alloc = 'lib/scheduling/day_allocation.dart'

$applied = 0
$missed = @()

function TryReplace {
  param($path, $from, $to, $label)
  $text = Get-Content -Raw $path
  if (-not $text.Contains($from)) { $script:missed += $label; return }
  Set-Content -Path $path -Value $text.Replace($from, $to) -NoNewline
  $script:applied++
}

# ── day_allocation.dart：目标同源 + even 参与日 ──────────────────────────────
TryReplace $alloc `
  "    required this.granularityMinutes,`r`n    this.maxReallocationPasses = 3," `
  "    required this.granularityMinutes,`r`n    Map<String, int>? targetMinutesByTask,`r`n    Map<String, int> alreadyScheduledMinutesByTask = const {},`r`n    this.maxReallocationPasses = 3," `
  'alloc 构造参数'

TryReplace $alloc `
  "       cycleStartByTask = UnmodifiableMapView(Map.of(cycleStartByTask)) {" `
  "       cycleStartByTask = UnmodifiableMapView(Map.of(cycleStartByTask)),`r`n       targetMinutesByTask = targetMinutesByTask == null ? null : UnmodifiableMapView(Map.of(targetMinutesByTask)),`r`n       alreadyScheduledMinutesByTask = UnmodifiableMapView(Map.of(alreadyScheduledMinutesByTask)) {" `
  'alloc 字段初始化'

TryReplace $alloc `
  "  final int granularityMinutes;`r`n`r`n  /// 最多执行几轮" `
  "  final int granularityMinutes;`r`n  final Map<String, int>? targetMinutesByTask;`r`n  final Map<String, int> alreadyScheduledMinutesByTask;`r`n`r`n  /// 最多执行几轮" `
  'alloc 字段声明'

TryReplace $alloc `
  "    final remaining =`r`n        task.requiredMinutes -`r`n        (planned.values.fold<int>(0, (sum, value) => sum + value));" `
  "    final plannedTotal = planned.values.fold<int>(0, (sum, value) => sum + value);`r`n    final target = input.targetMinutesByTask?[task.id] ?? task.requiredMinutes;`r`n    final remaining = target - (plannedTotal - (input.alreadyScheduledMinutesByTask[task.id] ?? 0));" `
  'alloc 目标同源'

TryReplace $alloc `
  "    final participantCount = neededChunks < ranked.length`r`n        ? neededChunks`r`n        : ranked.length;" `
  "    final participantCount =`r`n        task.distributionPolicy == TaskDistributionPolicy.even`r`n        ? ranked.length`r`n        : (neededChunks < ranked.length ? neededChunks : ranked.length);" `
  'alloc even 参与日'

# ── schedule_engine.dart：改用跨日分配 ───────────────────────────────────────
TryReplace $engine `
  "    final evenPlans = <String, EvenDistributionPlan>{`r`n      for (final task in problem.tasks)`r`n        if (task.distributionPolicy == TaskDistributionPolicy.even)`r`n          task.id: allocateEvenDistribution(`r`n            EvenDistributionInput(`r`n              targetMinutes: math.max(`r`n                0,`r`n                targets[task.id]! - (scheduledByTask[task.id] ?? 0),`r`n              ),`r`n              granularityMinutes: problem.rules.granularityMinutes,`r`n              minChunkMinutes: task.minChunkMinutes,`r`n              capacityMinutesByLocalDate: _capacityByLocalDate(`r`n                task,`r`n                slots,`r`n                problem.rules.granularityMinutes,`r`n              ),`r`n`r`n              alreadyPlannedMinutesByLocalDate: _plannedMinutesByLocalDate(`r`n                problem,`r`n                task,`r`n                problem.lockedBlocks,`r`n              ),`r`n            ),`r`n          ),`r`n    };" `
  "    final allocationPlan = allocateTaskDays(`r`n      DayAllocationInput(`r`n        tasks: problem.tasks,`r`n        ledger: ledger,`r`n        alreadyPlannedByTask: {`r`n          for (final task in problem.tasks)`r`n            task.id: _plannedMinutesByLocalDate(problem, task, problem.lockedBlocks),`r`n        },`r`n        timeZoneId: problem.timeZoneId,`r`n        cycleStartByTask: _cycleStartsByTask(problem),`r`n        granularityMinutes: problem.rules.granularityMinutes,`r`n        targetMinutesByTask: {`r`n          for (final task in problem.tasks)`r`n            task.id: math.max(0, targets[task.id]! - (scheduledByTask[task.id] ?? 0)),`r`n        },`r`n        alreadyScheduledMinutesByTask: {`r`n          for (final task in problem.tasks) task.id: scheduledByTask[task.id] ?? 0,`r`n        },`r`n        maxAllocationStates: maxAllocationStates,`r`n      ),`r`n    );" `
  'engine 分配调用'

TryReplace $engine `
  "      final evenPlanForTask = evenPlans[task.id];`r`n      final evenBudgetDates = evenPlanForTask?.additionalMinutesByLocalDate;" `
  "      final taskBudget = allocationPlan.budgetFor(task.id);`r`n      final budgetMinutesByDate = taskBudget?.minutesByLocalDate ?? const {};" `
  'engine 预算取值'

TryReplace $engine `
  "                  evenBudgetDates == null ||`r`n                  evenBudgetDates.containsKey(candidate.localDate)," `
  "                  budgetMinutesByDate.isEmpty ||`r`n                  budgetMinutesByDate.containsKey(candidate.localDate)," `
  'engine 候选剪枝'

TryReplace $engine `
  "        var ranked = <_RankedCandidate>[];`r`n        final evenPlan = evenPlanForTask;`r`n        final relaxedDailyQuota = evenPlan != null;" `
  "        var ranked = <_RankedCandidate>[];`r`n        const relaxedDailyQuota = false;`r`n        final budgetPlan = taskBudget;" `
  'engine 配额不放宽'

TryReplace $engine `
  "pass < (evenPlan == null ? 2 : 1) && ranked.isEmpty;" `
  "pass < (budgetPlan == null ? 2 : 1) && ranked.isEmpty;" `
  'engine pass 次数'

TryReplace $engine `
  "allowUnschedulableLeftover = evenPlan != null || pass == 1;" `
  "allowUnschedulableLeftover = budgetPlan != null || pass == 1;" `
  'engine 短尾放宽'

TryReplace $engine `
  "            plannedMinutesForTaskByDate: _taskMinutesByLocalDate(`r`n              problem,`r`n              task,`r`n              blocks,`r`n            ),`r`n            budgetPolicy: evenPlan == null`r`n                ? null`r`n                : (candidate) => _evenBudgetRemaining(`r`n                    problem,`r`n                    task,`r`n                    candidate,`r`n                    evenPlan,`r`n                    blocks,`r`n                  )," `
  "            plannedMinutesForTaskByDate: taskMinutesByDate[task.id] ?? const <DateTime, int>{},`r`n            budgetPolicy: budgetPlan == null`r`n                ? null`r`n                : (candidate) => _budgetRemaining(candidate, budgetPlan, taskMinutesByDate[task.id] ?? const <DateTime, int>{})," `
  'engine 预算策略'

TryReplace $engine `
  "        blocks.add(block);`r`n        chargeMovable(block);" `
  "        blocks.add(block);`r`n        chargeMovable(block);`r`n        chargeTaskMinutes(block);" `
  'engine 增量表记账'

TryReplace $engine `
  "    void chargeMovable(PlannedBlock block) {" `
  "    final taskMinutesByDate = <String, Map<DateTime, int>>{};`r`n    void chargeTaskMinutes(PlannedBlock block) {`r`n      final byDate = taskMinutesByDate.putIfAbsent(block.taskId, () => <DateTime, int>{});`r`n      final date = _localDate(block.startUtc, problem.timeZoneId);`r`n      byDate[date] = (byDate[date] ?? 0) + block.durationMinutes;`r`n    }`r`n    for (final block in blocks) { chargeTaskMinutes(block); }`r`n`r`n    void chargeMovable(PlannedBlock block) {" `
  'engine 增量表声明'

TryReplace $engine `
  "  DeterministicScheduleEngine(this._zones)`r`n    : _availabilityBuilder = AvailabilityBuilder(_zones),`r`n      _validator = PlanValidator(_zones);" `
  "  DeterministicScheduleEngine(this._zones, {this.maxAllocationStates = 10000})`r`n    : _availabilityBuilder = AvailabilityBuilder(_zones),`r`n      _validator = PlanValidator(_zones);`r`n`r`n  final int maxAllocationStates;" `
  'engine 构造参数'

TryReplace $engine `
  "import 'package:personal_planner/scheduling/day_capacity_ledger.dart';" `
  "import 'package:personal_planner/scheduling/day_allocation.dart';`r`nimport 'package:personal_planner/scheduling/day_capacity_ledger.dart';" `
  'engine import'

# 收尾：替换旧预算函数为查表版本
$text = Get-Content -Raw $engine
$s = $text.IndexOf('  int _evenBudgetRemaining(')
$e = $text.IndexOf('  /// 同一任务在该候选所在本地日是否已有其它片段。')
if ($s -ge 0 -and $e -gt $s) {
  $new = @"
  int _budgetRemaining(SchedulingCandidate candidate, TaskDayBudget budget, Map<DateTime, int> taskMinutesByDate) {
    final allowed = budget.minutesByLocalDate[candidate.localDate] ?? 0;
    if (allowed <= 0) return 0;
    return allowed - (taskMinutesByDate[candidate.localDate] ?? 0);
  }

"@
  Set-Content -Path $engine -Value ($text.Substring(0, $s) + $new + $text.Substring($e)) -NoNewline
  $applied++
} else { $missed += 'engine 预算函数替换' }

# 加 cycle 辅助函数
$text = Get-Content -Raw $engine
$old = @"
  DateTime _localDate(DateTime instantUtc, String zoneId) {
    final local = _zones.toLocal(instantUtc, zoneId);
    return DateTime(local.year, local.month, local.day);
  }
}
"@
if ($text.Contains($old)) {
  $new = @"
  DateTime _localDate(DateTime instantUtc, String zoneId) {
    final local = _zones.toLocal(instantUtc, zoneId);
    return DateTime(local.year, local.month, local.day);
  }

  /// 周期实例的「周期起点本地日期」表（计划 §3.4 第 7 条）。
  Map<String, DateTime> _cycleStartsByTask(ScheduleProblem problem) {
    final result = <String, DateTime>{};
    for (final task in problem.tasks) {
      final start = _cycleStartOf(task.id);
      if (start == null) continue;
      result[task.id] = start;
    }
    return result;
  }

  /// 形状 `recurring:<templateId>:<yyyy-MM-dd>`；不匹配返回 null（不猜）。
  DateTime? _cycleStartOf(String taskId) {
    if (!taskId.startsWith('recurring:')) return null;
    final lastColon = taskId.lastIndexOf(':');
    if (lastColon <= 0 || lastColon == taskId.length - 1) return null;
    final parts = taskId.substring(lastColon + 1).split('-');
    if (parts.length != 3) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final day = int.tryParse(parts[2]);
    if (year == null || month == null || day == null) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }
}
"@
  Set-Content -Path $engine -Value $text.Replace($old, $new) -NoNewline
  $applied++
} else { $missed += 'engine cycle 辅助' }

# 删掉不再使用的 even 分配器 import 与两个死函数
$text = Get-Content -Raw $engine
$text = $text -replace "(?m)^import 'package:personal_planner/scheduling/even_distribution_allocator\.dart';\r?\n", ''
foreach ($pair in @(
  @('  Map<DateTime, int> _capacityByLocalDate(', '  /// 可用时段真正覆盖到的本地日集合。'),
  @('  /// 可用时段真正覆盖到的本地日集合。', '  /// 该任务在这些块上按本地日期已经占用的分钟。')
)) {
  $s2 = $text.IndexOf($pair[0]); $e2 = $text.IndexOf($pair[1])
  if ($s2 -ge 0 -and $e2 -gt $s2) { $text = $text.Substring(0, $s2) + $text.Substring($e2) }
}
Set-Content -Path $engine -Value $text -NoNewline

Write-Output "接线完成：$applied 处改动成功"
if ($missed.Count -gt 0) { Write-Output "未匹配（需人工检查）：$($missed -join ', ')" }
