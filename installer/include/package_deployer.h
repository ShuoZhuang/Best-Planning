// 安装动作决策与部署（规格 §9.4–§9.7）。
//
// 决策只看实际登记结果：不信任安装请求里的"目标版本"，也不在部署失败后
// 仅凭一次 API 异常推断包没有变化（§9.5）。
#pragma once

#include <windows.h>

#include <string>

#include "installer_errors.h"
#include "native_shared/package_deployment.h"
#include "payload_metadata.h"

namespace planner::installer {

enum class InstallAction {
  Install,
  Upgrade,
  Repair,      // 重新安装同一版本
  LaunchOnly,  // 当前版本已是目标版本
  Blocked,
};

struct InstallState {
  bool installed = false;
  bool running = false;
  DWORD running_process = 0;
  InstallAction action = InstallAction::Install;
  planner::native::InstalledPackage package;
  planner::native::PackageVersion version;
  bool version_is_target = false;
  bool version_is_newer = false;
  bool publisher_conflict = false;
};

bool QueryInstallState(const PayloadMetadata& metadata, InstallState& state,
                       ErrorCode& error, std::wstring& detail);

// 以**当前（未提权）进程**的用户身份部署。失败时保留旧版本。
bool DeployPackage(const std::wstring& path, HRESULT& deployment_error,
                   ErrorCode& error, std::wstring& detail);

// 同版本重新安装：覆盖已安装的同一版本，不先卸载（规格 §9.6）。
bool ReinstallPackage(const std::wstring& path, HRESULT& deployment_error,
                      ErrorCode& error, std::wstring& detail);

bool RepairPackage(const planner::native::InstalledPackage& installed,
                   ErrorCode& error, std::wstring& detail);

bool VerifyInstalledTarget(const PayloadMetadata& metadata,
                           planner::native::InstalledPackage& installed,
                           ErrorCode& error, std::wstring& detail);

}  // namespace planner::installer
