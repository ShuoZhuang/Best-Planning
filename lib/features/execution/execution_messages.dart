import 'package:personal_planner/domain/execution/execution_result.dart';

/// 把封闭结果枚举映射成用户文案（规范 §19.3）。
///
/// **集中维护**：页面不拼内部枚举名、异常文本或 SQL；同一个失败在任何入口给出同一句话。
String executionMessageFor(ExecutionCommandResult result) {
  switch (result.status) {
    case ExecutionResultStatus.applied:
    case ExecutionResultStatus.alreadyApplied:
      return '已保存';
    case ExecutionResultStatus.activeSessionConflict:
      return '已有一段执行正在进行，请先结束或暂停它';
    case ExecutionResultStatus.blockedByHardBoundary:
      final available = result.parameters['availableMicros'];
      if (available is int && available > 0) {
        final minutes = available ~/ Duration.microsecondsPerMinute;
        return minutes <= 0 ? '当前只剩不到一分钟，可以只记录实际' : '现在最多还能做 $minutes 分钟，仍要开始吗';
      }
      return '当前时段被课程或保护时间占用，换一个时间再开始';
    case ExecutionResultStatus.notificationsDisabled:
      return '提醒已关闭，未设置系统提醒';
    case ExecutionResultStatus.needsConfirmation:
      return '这段时间与已有记录重叠，需要先选择处理方式';
    case ExecutionResultStatus.stale:
      return '这条安排已经变化，请刷新后重试';
    case ExecutionResultStatus.notFound:
      return '找不到这条安排或记录';
    case ExecutionResultStatus.outsidePlanBoundary:
      return '已超过计划边界，可以只记录实际投入';
    case ExecutionResultStatus.sourceMappingMissing:
      return '找不到这条安排对应的原计划块，未写入计划';
    case ExecutionResultStatus.storageFailed:
      return '未保存，请检查磁盘空间后重试';
    case ExecutionResultStatus.invalid:
      switch (result.reasonCode) {
        case ExecutionReasonCode.operationIdReused:
          return '这次操作与之前提交的内容不一致，已拒绝重复使用';
        case ExecutionReasonCode.noRemainingWork:
          return '这项任务已经没有剩余时长';
        case ExecutionReasonCode.taskClosed:
          return '任务已经结束';
        case ExecutionReasonCode.invalidNote:
          return '备注过长或包含不允许的控制字符';
        case ExecutionReasonCode.invalidDuration:
          return '时长或结束时间无效';
        case ExecutionReasonCode.overlapRejected:
          return '重叠区间没有可入账的部分';
        case ExecutionReasonCode.notificationsDisabled:
          return '提醒已关闭';
        case ExecutionReasonCode.illegalTransition:
          return '当前状态不允许这个操作，请刷新';
        default:
          return '操作无效，请刷新后重试';
      }
  }
}
