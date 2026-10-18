// 更新错误模型（规格 §14）。
//
// **这一层存在的理由**：更新链路上失败的方式很多，而"失败"与"没有更新"是两种完全不同的
// 事实。规格 §14.1 把每次检查的结果限定为四类，其中只有"已验证且确认无更新"可以显示
// "已经是最新版"；网络失败、空响应、304 无缓存都不能被折叠成它。
//
// 错误码格式固定为 `UPDATE_<STAGE>_<REASON>`。每个码同时带三样东西：
//   · 是否可以重试（决定退避还是就此停下）；
//   · 给用户看的一句话（界面只渲染它，**不渲染异常对象或本地路径**）；
//   · 所属阶段（诊断页与日志据此分组）。
library;

/// 错误所属阶段。与错误码前缀一一对应，但单独列出来是为了让界面能按阶段分组而不用解析字符串。
enum UpdateStage {
  network('网络'),
  manifest('清单'),
  download('下载'),
  verification('包验证'),
  blocked('阻塞'),
  helper('更新助手'),
  install('安装'),
  health('健康确认'),
  rollback('回退'),
  state('状态'),
  internal('内部');

  const UpdateStage(this.label);

  final String label;
}

/// 更新链路可能产生的全部结构化错误。
///
/// 枚举而不是字符串：界面文案、重试策略与测试断言都从同一份定义取值，因此不会出现
/// "日志里是 A、界面显示 B、测试断言 C"的三份真相。
enum UpdateFailureCode {
  // ── 检查和清单（规格 §14.2）────────────────────────────────────────────────
  networkOffline('UPDATE_NETWORK_OFFLINE', UpdateStage.network,
      retryable: true, message: '网络不可用'),
  networkTimeout('UPDATE_NETWORK_TIMEOUT', UpdateStage.network,
      retryable: true, message: '网络请求超时'),
  networkTlsFailed('UPDATE_NETWORK_TLS_FAILED', UpdateStage.network,
      retryable: true, message: '安全连接建立失败'),
  networkHttpFailed('UPDATE_NETWORK_HTTP_FAILED', UpdateStage.network,
      retryable: true, message: '更新服务器返回了错误'),
  manifestNotModifiedWithoutCache(
      'UPDATE_MANIFEST_NOT_MODIFIED_WITHOUT_CACHE', UpdateStage.manifest,
      retryable: true, message: '更新信息暂时无法确认'),
  manifestEmpty('UPDATE_MANIFEST_EMPTY', UpdateStage.manifest,
      retryable: true, message: '更新服务器返回了空内容'),
  manifestInvalidJson('UPDATE_MANIFEST_INVALID_JSON', UpdateStage.manifest,
      retryable: false, message: '更新信息格式异常'),
  manifestSchemaUnsupported(
      'UPDATE_MANIFEST_SCHEMA_UNSUPPORTED', UpdateStage.manifest,
      retryable: false, message: '更新信息版本不受支持'),
  manifestSignatureInvalid(
      'UPDATE_MANIFEST_SIGNATURE_INVALID', UpdateStage.manifest,
      retryable: false, message: '更新信息的签名无效'),
  manifestSourceNotAllowed(
      'UPDATE_MANIFEST_SOURCE_NOT_ALLOWED', UpdateStage.manifest,
      retryable: false, message: '更新来源不在允许范围内'),
  manifestVersionInconsistent(
      'UPDATE_MANIFEST_VERSION_INCONSISTENT', UpdateStage.manifest,
      retryable: false, message: '更新信息里的版本互相矛盾'),

  // ── 下载（规格 §14.2）──────────────────────────────────────────────────────
  downloadDiskSpaceLow('UPDATE_DOWNLOAD_DISK_SPACE_LOW', UpdateStage.download,
      retryable: true, message: '磁盘空间不足，下载已暂停'),
  downloadPermissionDenied(
      'UPDATE_DOWNLOAD_PERMISSION_DENIED', UpdateStage.download,
      retryable: false, message: '没有权限写入更新文件'),
  downloadRangeRejected('UPDATE_DOWNLOAD_RANGE_REJECTED', UpdateStage.download,
      retryable: true, message: '断点续传被服务器拒绝'),
  downloadRemoteChanged('UPDATE_DOWNLOAD_REMOTE_CHANGED', UpdateStage.download,
      retryable: true, message: '服务器上的更新包已经变化'),
  downloadSizeMismatch('UPDATE_DOWNLOAD_SIZE_MISMATCH', UpdateStage.download,
      retryable: true, message: '下载的更新包大小不正确'),
  downloadHashMismatch('UPDATE_DOWNLOAD_HASH_MISMATCH', UpdateStage.download,
      retryable: true, message: '下载的更新包校验失败'),
  downloadCancelledByNewVersion(
      'UPDATE_DOWNLOAD_CANCELLED_BY_NEW_VERSION', UpdateStage.download,
      retryable: true, message: '发现更高版本，已切换到新版本'),
  downloadRetryExhausted('UPDATE_DOWNLOAD_RETRY_EXHAUSTED', UpdateStage.download,
      retryable: false, message: '多次重试仍无法下载更新包'),

  // ── 包验证（规格 §14.2）────────────────────────────────────────────────────
  packageFormatInvalid('UPDATE_PACKAGE_FORMAT_INVALID', UpdateStage.verification,
      retryable: false, message: '更新包格式不正确'),
  packageSignatureMissing(
      'UPDATE_PACKAGE_SIGNATURE_MISSING', UpdateStage.verification,
      retryable: false, message: '更新包缺少签名'),
  packageSignatureInvalid(
      'UPDATE_PACKAGE_SIGNATURE_INVALID', UpdateStage.verification,
      retryable: false, message: '更新包签名无效'),
  packageCertificateUntrusted(
      'UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED', UpdateStage.verification,
      retryable: false, message: '更新包证书不受信任'),
  packagePublisherMismatch(
      'UPDATE_PACKAGE_PUBLISHER_MISMATCH', UpdateStage.verification,
      retryable: false, message: '更新包发布者与当前版本不一致'),
  packageIdentityMismatch(
      'UPDATE_PACKAGE_IDENTITY_MISMATCH', UpdateStage.verification,
      retryable: false, message: '更新包身份与当前版本不一致'),
  packageFamilyMismatch('UPDATE_PACKAGE_FAMILY_MISMATCH', UpdateStage.verification,
      retryable: false, message: '更新包包族名与当前版本不一致'),
  packageArchMismatch('UPDATE_PACKAGE_ARCH_MISMATCH', UpdateStage.verification,
      retryable: false, message: '更新包架构与当前版本不一致'),
  packageOsUnsupported('UPDATE_PACKAGE_OS_UNSUPPORTED', UpdateStage.verification,
      retryable: false, message: '当前 Windows 版本不受支持'),
  packageVersionSame('UPDATE_PACKAGE_VERSION_SAME', UpdateStage.verification,
      retryable: false, message: '更新包与当前版本相同'),
  packageDowngradeBlocked(
      'UPDATE_PACKAGE_DOWNGRADE_BLOCKED', UpdateStage.verification,
      retryable: false, message: '不允许降级安装'),
  packageVersionRevoked('UPDATE_PACKAGE_VERSION_REVOKED', UpdateStage.verification,
      retryable: false, message: '该版本已被撤回'),
  packageVersionMismatch(
      'UPDATE_PACKAGE_VERSION_MISMATCH', UpdateStage.verification,
      retryable: false, message: '更新包内部版本与清单不一致'),

  // ── 阻塞（规格 §14.2）──────────────────────────────────────────────────────
  blockedUnsavedChanges('UPDATE_BLOCKED_UNSAVED_CHANGES', UpdateStage.blocked,
      retryable: true, message: '请先保存或取消当前编辑，再进行更新。'),
  blockedDatabaseTransaction(
      'UPDATE_BLOCKED_DATABASE_TRANSACTION', UpdateStage.blocked,
      retryable: true, message: '正在完成数据操作，完成后即可更新。'),
  blockedPlanApplying('UPDATE_BLOCKED_PLAN_APPLYING', UpdateStage.blocked,
      retryable: true, message: '正在完成数据操作，完成后即可更新。'),
  blockedImportRunning('UPDATE_BLOCKED_IMPORT_RUNNING', UpdateStage.blocked,
      retryable: true, message: '正在完成数据操作，完成后即可更新。'),
  blockedBackupRunning('UPDATE_BLOCKED_BACKUP_RUNNING', UpdateStage.blocked,
      retryable: true, message: '正在完成数据操作，完成后即可更新。'),
  blockedRollbackNotReady(
      'UPDATE_BLOCKED_ROLLBACK_NOT_READY', UpdateStage.blocked,
      retryable: true, message: '正在准备回退基线，完成后即可更新。'),
  blockedDiskSpaceLow('UPDATE_BLOCKED_DISK_SPACE_LOW', UpdateStage.blocked,
      retryable: true, message: '磁盘空间不足，暂时无法安装更新。'),
  blockedInstallerBusy('UPDATE_BLOCKED_INSTALLER_BUSY', UpdateStage.blocked,
      retryable: true, message: '另一个更新操作正在进行。'),

  // ── 助手、安装和回退（规格 §14.2）─────────────────────────────────────────
  helperMissing('UPDATE_HELPER_MISSING', UpdateStage.helper,
      retryable: false, message: '更新助手缺失'),
  helperSignatureInvalid('UPDATE_HELPER_SIGNATURE_INVALID', UpdateStage.helper,
      retryable: false, message: '更新助手签名无效'),
  helperVersionIncompatible(
      'UPDATE_HELPER_VERSION_INCOMPATIBLE', UpdateStage.helper,
      retryable: false, message: '更新助手版本不兼容'),
  helperLocked('UPDATE_HELPER_LOCKED', UpdateStage.helper,
      retryable: true, message: '更新助手正忙'),
  helperLaunchFailed('UPDATE_HELPER_LAUNCH_FAILED', UpdateStage.helper,
      retryable: true, message: '无法启动更新助手'),
  helperRequestInvalid('UPDATE_HELPER_REQUEST_INVALID', UpdateStage.helper,
      retryable: false, message: '更新请求无效'),
  helperProcessExitTimeout(
      'UPDATE_HELPER_PROCESS_EXIT_TIMEOUT', UpdateStage.helper,
      retryable: true, message: '等待程序退出超时'),
  installPackageInUse('UPDATE_INSTALL_PACKAGE_IN_USE', UpdateStage.install,
      retryable: true, message: '更新包正在被占用'),
  installDeploymentBusy('UPDATE_INSTALL_DEPLOYMENT_BUSY', UpdateStage.install,
      retryable: true, message: '系统安装服务忙，稍后重试'),
  installDiskFull('UPDATE_INSTALL_DISK_FULL', UpdateStage.install,
      retryable: true, message: '安装时磁盘空间不足'),
  installCertificateFailed(
      'UPDATE_INSTALL_CERTIFICATE_FAILED', UpdateStage.install,
      retryable: false, message: '更新包证书无法通过验证'),
  installDependencyMissing(
      'UPDATE_INSTALL_DEPENDENCY_MISSING', UpdateStage.install,
      retryable: false, message: '更新包缺少必要的系统组件'),
  installPolicyBlocked('UPDATE_INSTALL_POLICY_BLOCKED', UpdateStage.install,
      retryable: false, message: '系统策略阻止了安装'),
  installDeploymentFailed(
      'UPDATE_INSTALL_DEPLOYMENT_FAILED', UpdateStage.install,
      retryable: true, message: '安装失败，当前版本未受影响'),
  installResultUnknown('UPDATE_INSTALL_RESULT_UNKNOWN', UpdateStage.install,
      retryable: true, message: '安装结果未知'),
  installTargetPaused('UPDATE_INSTALL_TARGET_PAUSED', UpdateStage.install,
      retryable: false, message: '该版本上次更新失败，已暂停自动安装；可手动重试。'),
  healthProcessNotStarted(
      'UPDATE_HEALTH_PROCESS_NOT_STARTED', UpdateStage.health,
      retryable: true, message: '新版本没有启动'),
  healthStartupTimeout('UPDATE_HEALTH_STARTUP_TIMEOUT', UpdateStage.health,
      retryable: true, message: '新版本启动超时'),
  healthVersionMismatch('UPDATE_HEALTH_VERSION_MISMATCH', UpdateStage.health,
      retryable: false, message: '新版本报告了错误的版本号'),
  healthDatabaseOpenFailed(
      'UPDATE_HEALTH_DATABASE_OPEN_FAILED', UpdateStage.health,
      retryable: false, message: '新版本无法打开数据库'),
  healthMigrationFailed('UPDATE_HEALTH_MIGRATION_FAILED', UpdateStage.health,
      retryable: false, message: '数据迁移失败'),
  healthUiInitFailed('UPDATE_HEALTH_UI_INIT_FAILED', UpdateStage.health,
      retryable: false, message: '新版本界面初始化失败'),
  rollbackPackageMissing(
      'UPDATE_ROLLBACK_PACKAGE_MISSING', UpdateStage.rollback,
      retryable: true, message: '找不到可回退的旧版本安装包'),
  rollbackPackageInvalid(
      'UPDATE_ROLLBACK_PACKAGE_INVALID', UpdateStage.rollback,
      retryable: false, message: '旧版本安装包已损坏'),
  rollbackDataRestoreFailed(
      'UPDATE_ROLLBACK_DATA_RESTORE_FAILED', UpdateStage.rollback,
      retryable: false, message: '恢复更新前数据失败'),
  rollbackDeploymentFailed(
      'UPDATE_ROLLBACK_DEPLOYMENT_FAILED', UpdateStage.rollback,
      retryable: true, message: '回退安装失败'),
  rollbackSucceeded('UPDATE_ROLLBACK_SUCCEEDED', UpdateStage.rollback,
      retryable: false, message: '已回退到更新前的版本'),

  // ── 本实现额外需要、规格未列出的码（规格 §14.2 是"至少覆盖"）─────────────
  stateIllegalTransition('UPDATE_STATE_ILLEGAL_TRANSITION', UpdateStage.state,
      retryable: false, message: '更新状态推进被拒绝'),
  stateCorrupt('UPDATE_STATE_CORRUPT', UpdateStage.state,
      retryable: true, message: '更新状态文件损坏，正在重建'),
  stateWriteFailed('UPDATE_STATE_WRITE_FAILED', UpdateStage.state,
      retryable: true, message: '无法保存更新状态'),
  snapshotFailed('UPDATE_SNAPSHOT_FAILED', UpdateStage.state,
      retryable: true, message: '无法生成更新前的数据快照'),
  snapshotInvalid('UPDATE_SNAPSHOT_INVALID', UpdateStage.state,
      retryable: false, message: '更新前的数据快照不完整'),
  healthConfirmationInvalid(
      'UPDATE_HEALTH_CONFIRMATION_INVALID', UpdateStage.health,
      retryable: false, message: '健康确认与实际版本不匹配'),
  environmentNotPackaged('UPDATE_ENVIRONMENT_NOT_PACKAGED', UpdateStage.internal,
      retryable: false, message: '当前不是以安装包方式运行，无法检查更新'),
  internalError('UPDATE_INTERNAL_ERROR', UpdateStage.internal,
      retryable: true, message: '更新过程发生未预期的问题');

  const UpdateFailureCode(
    this.code,
    this.stage, {
    required this.retryable,
    required this.message,
  });

  /// `UPDATE_<STAGE>_<REASON>`。日志与状态文件只写它，不写 `name`。
  final String code;

  final UpdateStage stage;

  /// 是否属于"可以自动重试"的暂时性错误（规格 §14.3）。
  final bool retryable;

  /// 给用户看的一句话。界面**只**渲染它。
  final String message;

  /// 确定性错误（签名、身份、撤回、系统不兼容等）不得高频重试。
  bool get deterministic => !retryable;

  static UpdateFailureCode? fromCode(String? code) {
    if (code == null) return null;
    for (final value in UpdateFailureCode.values) {
      if (value.code == code) return value;
    }
    return null;
  }
}

/// 一次失败的结构化记录。
///
/// [detail] 只允许放**不敏感**的技术细节（例如 Windows 结果码、期望/实际字节数）。
/// 业务标题、备注、UUID、数据库正文、令牌与证书私钥一律不得进入这里（规格 §14.4）。
final class UpdateFailure {
  const UpdateFailure(
    this.code, {
    this.detail,
    this.windowsResultCode,
    this.occurredAtUtc,
    this.attempt = 0,
  });

  final UpdateFailureCode code;
  final String? detail;

  /// Windows API 的 `HRESULT`/错误码。日志与诊断页显示它，便于对照系统文档。
  final int? windowsResultCode;

  final DateTime? occurredAtUtc;

  /// 本次失败前已经重试的次数。用于退避与"重试已用尽"的判定。
  final int attempt;

  bool get retryable => code.retryable;

  /// 给用户的一句话；确定性错误也用它，不拼接异常信息。
  String get userMessage => code.message;

  /// 日志行。刻意保持单行，避免日志文件被多行堆栈撑大。
  String get diagnosticLine {
    final buffer = StringBuffer(code.code);
    if (detail != null && detail!.isNotEmpty) {
      buffer.write(' detail=${_sanitize(detail!)}');
    }
    if (windowsResultCode != null) {
      buffer.write(
        ' hresult=0x${windowsResultCode!.toUnsigned(32).toRadixString(16)}',
      );
    }
    if (occurredAtUtc != null) {
      buffer.write(' at=${occurredAtUtc!.toUtc().toIso8601String()}');
    }
    if (attempt > 0) buffer.write(' attempt=$attempt');
    return buffer.toString();
  }

  static String _sanitize(String value) =>
      value.replaceAll(RegExp(r'[\r\n\t]'), ' ').trim();

  @override
  String toString() => code.code;
}

/// 一次检查的四种合法结论（规格 §14.1）。
enum UpdateCheckClassification {
  /// 已验证且确认无更新。**只有这一类可以显示"已经是最新版"**。
  upToDate,

  /// 已验证且发现更新。
  updateAvailable,

  /// 暂时无法确认（离线、超时、304 无缓存、空响应……）。
  temporarilyUnconfirmed,

  /// 更新源或安装包异常（签名、来源、版本自相矛盾……）。
  sourceInvalid,
}

/// 把失败映射到四种检查结论之一。
///
/// 规则刻意简单且可穷举：网络与空响应是"暂时无法确认"，清单本身不合法是"更新源异常"。
/// 任何新增错误码都必须在这里有一个归属，否则编译期就会提示 `switch` 不完整。
UpdateCheckClassification classificationFor(UpdateFailureCode code) =>
    switch (code) {
      UpdateFailureCode.networkOffline ||
      UpdateFailureCode.networkTimeout ||
      UpdateFailureCode.networkTlsFailed ||
      UpdateFailureCode.networkHttpFailed ||
      UpdateFailureCode.manifestNotModifiedWithoutCache ||
      UpdateFailureCode.manifestEmpty ||
      UpdateFailureCode.environmentNotPackaged =>
        UpdateCheckClassification.temporarilyUnconfirmed,
      UpdateFailureCode.manifestInvalidJson ||
      UpdateFailureCode.manifestSchemaUnsupported ||
      UpdateFailureCode.manifestSignatureInvalid ||
      UpdateFailureCode.manifestSourceNotAllowed ||
      UpdateFailureCode.manifestVersionInconsistent =>
        UpdateCheckClassification.sourceInvalid,
      _ => UpdateCheckClassification.sourceInvalid,
    };
