// 稳定错误编号与界面文案（规格 §11.5）。
//
// 界面只展示这里的原因与处理建议；HRESULT、异常文本和调用栈只写日志。
#pragma once

#include <string>

#include "installer_state.h"

namespace planner::installer {

enum class ErrorCode {
  None,
  Cancelled,
  PayloadMissing,
  PayloadSizeMismatch,
  PayloadHashMismatch,
  MetadataInvalid,
  MetadataVersionUnsupported,
  IdentityMismatch,
  PublisherMismatch,
  ArchitectureMismatch,
  VersionMismatch,
  SignatureInvalid,
  CertificateUntrusted,
  CertificateImportFailed,
  CertificateStoreUnavailable,
  ElevationDeclined,
  ElevationFailed,
  ElevationResourceMismatch,
  AppRunning,
  UnsupportedWindows,
  UnsupportedArchitecture,
  InsufficientDiskSpace,
  TempUnavailable,
  PackageManagerUnavailable,
  DeploymentFailed,
  DeploymentFailedNotInstalled,
  DowngradeRejected,
  IdentityConflict,
  LaunchFailed,
  Indeterminate,
  Internal,
  AlreadyRunning,
  PendingRestart,
};

struct ErrorDescription {
  const wchar_t* code;    // 稳定编号（写日志、复制信息）
  const wchar_t* title;   // 简明标题
  const wchar_t* reason;  // 用户能理解的原因
  const wchar_t* action;  // 推荐处理方式
  ExitCode exit;          // 规格 §10.4
};

ErrorDescription DescribeError(ErrorCode code);

// 把共享库的稳定令牌（`UPDATE_PACKAGE_*` / `INSTALLER_DEPLOY_*`）映射为界面错误。
ErrorCode ErrorFromStableCode(const std::wstring& stable_code);

}  // namespace planner::installer
