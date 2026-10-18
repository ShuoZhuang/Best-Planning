// 一次检查的结论（规格 §14.1）。
//
// **四类结果里只有一类能显示"已经是最新版"**：通过签名验证、与当前版本比较后确认无更新。
// 网络失败、空响应、304 无缓存都必须落在 [temporarilyUnconfirmed] 或 [sourceInvalid]，
// 而不是被折叠成"无更新"——那正是旧实现最危险的一种"静默做错"。
import 'package:personal_planner/domain/update/package_identity.dart';
import 'package:personal_planner/domain/update/update_failure.dart';
import 'package:personal_planner/domain/update/update_ports.dart';
import 'package:personal_planner/domain/update/update_state.dart';

final class UpdateCheckResult {
  const UpdateCheckResult({
    required this.classification,
    required this.state,
    this.manifest,
    this.failure,
    this.installed,
  });

  final UpdateCheckClassification classification;

  /// 检查结束后的持久状态（界面与状态文件读的是同一个对象）。
  final UpdateState state;

  /// 只在验证通过时非空。
  final VerifiedManifest? manifest;

  /// 失败时为具体原因；成功时为 `null`。
  final UpdateFailure? failure;

  final InstalledPackage? installed;

  /// **只有这个为真才能显示"已经是最新版"**。
  bool get isConfirmedUpToDate =>
      classification == UpdateCheckClassification.upToDate && failure == null;

  bool get hasUpdate =>
      classification == UpdateCheckClassification.updateAvailable;

  bool get isTemporaryFailure =>
      classification == UpdateCheckClassification.temporarilyUnconfirmed;

  bool get isSourceInvalid =>
      classification == UpdateCheckClassification.sourceInvalid;
}
