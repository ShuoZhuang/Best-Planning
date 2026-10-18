#include "package_deployer.h"

#include "native_shared/deployment_errors.h"
#include "native_shared/planner_identity.h"
#include "native_shared/text.h"

namespace planner::installer {
namespace {

namespace nh = planner::native;

ErrorCode MapDeploymentFailure(HRESULT error) {
  const auto failure = nh::DescribeDeploymentFailure(error);
  if (_wcsicmp(failure.code, L"INSTALLER_DEPLOY_PACKAGE_IN_USE") == 0) {
    return ErrorCode::AppRunning;
  }
  if (_wcsicmp(failure.code, L"INSTALLER_DEPLOY_DOWNGRADE_REJECTED") == 0) {
    return ErrorCode::DowngradeRejected;
  }
  if (_wcsicmp(failure.code, L"INSTALLER_DEPLOY_CERTIFICATE_UNTRUSTED") == 0 ||
      _wcsicmp(failure.code, L"INSTALLER_DEPLOY_CERTIFICATE_CHAIN") == 0 ||
      _wcsicmp(failure.code, L"INSTALLER_DEPLOY_CERTIFICATE_DISTRUSTED") == 0) {
    return ErrorCode::CertificateUntrusted;
  }
  if (_wcsicmp(failure.code, L"INSTALLER_DEPLOY_PENDING_RESTART") == 0) {
    return ErrorCode::Indeterminate;
  }
  return ErrorCode::DeploymentFailed;
}

}  // namespace

bool QueryInstallState(const PayloadMetadata& metadata, InstallState& state,
                       ErrorCode& error, std::wstring& detail) {
  state = InstallState{};
  std::wstring query_error;
  planner::native::InstalledPackage installed;
  if (!nh::QueryInstalledPackage(metadata.identity_name, installed,
                                 query_error)) {
    error = ErrorCode::PackageManagerUnavailable;
    detail = query_error;
    return false;
  }
  if (!installed.found) {
    state.action = InstallAction::Install;
    error = ErrorCode::None;
    return true;
  }

  state.installed = true;
  state.package = installed;
  if (!nh::PackageVersion::Parse(installed.version, state.version)) {
    error = ErrorCode::Indeterminate;
    detail = L"installed-version-unparsable " + installed.version;
    return false;
  }
  if (!nh::SamePublisher(installed.publisher, metadata.publisher)) {
    state.publisher_conflict = true;
    state.action = InstallAction::Blocked;
    error = ErrorCode::IdentityConflict;
    detail = L"installed-publisher " + installed.publisher;
    return false;
  }

  const nh::PackageVersion target = metadata.MsixVersionValue();
  state.version_is_target = state.version == target;
  state.version_is_newer = state.version.IsHigherThan(target);
  if (state.version_is_newer) {
    state.action = InstallAction::Blocked;
    error = ErrorCode::DowngradeRejected;
    detail = L"installed " + installed.version + L" > target " +
             metadata.msix_version;
    return false;
  }
  state.action = state.version_is_target ? InstallAction::LaunchOnly
                                         : InstallAction::Upgrade;
  state.running = nh::IsPackageRunning(installed.family_name,
                                      state.running_process);
  error = ErrorCode::None;
  return true;
}

bool DeployPackage(const std::wstring& path, HRESULT& deployment_error,
                   ErrorCode& error, std::wstring& detail) {
  const auto result = nh::DeployPackage(path);
  deployment_error = result.error;
  if (result.ok) {
    error = ErrorCode::None;
    return true;
  }
  error = MapDeploymentFailure(result.error);
  wchar_t buffer[64]{};
  swprintf_s(buffer, L"0x%08X", static_cast<unsigned int>(result.error));
  detail = std::wstring(buffer) + L" " + result.error_text;
  return false;
}

bool ReinstallPackage(const std::wstring& path, HRESULT& deployment_error,
                      ErrorCode& error, std::wstring& detail) {
  const auto result = nh::ReinstallSameVersion(path);
  deployment_error = result.error;
  if (result.ok) {
    error = ErrorCode::None;
    return true;
  }
  error = MapDeploymentFailure(result.error);
  wchar_t buffer[64]{};
  swprintf_s(buffer, L"0x%08X", static_cast<unsigned int>(result.error));
  detail = std::wstring(buffer) + L" " + result.error_text;
  return false;
}

bool RepairPackage(const planner::native::InstalledPackage& installed,
                   ErrorCode& error, std::wstring& detail) {
  const auto result = nh::RegisterInstalledPackage(installed.full_name);
  if (result.ok) {
    error = ErrorCode::None;
    return true;
  }
  error = MapDeploymentFailure(result.error);
  wchar_t buffer[64]{};
  swprintf_s(buffer, L"0x%08X", static_cast<unsigned int>(result.error));
  detail = std::wstring(buffer) + L" " + result.error_text;
  return false;
}

bool VerifyInstalledTarget(const PayloadMetadata& metadata,
                           planner::native::InstalledPackage& installed,
                           ErrorCode& error, std::wstring& detail) {
  std::wstring query_error;
  if (!nh::QueryInstalledPackage(metadata.identity_name, installed,
                                 query_error)) {
    error = ErrorCode::PackageManagerUnavailable;
    detail = query_error;
    return false;
  }
  if (!installed.found) {
    error = ErrorCode::DeploymentFailedNotInstalled;
    detail = L"not-registered";
    return false;
  }
  nh::PackageVersion version;
  if (!nh::PackageVersion::Parse(installed.version, version)) {
    error = ErrorCode::Indeterminate;
    detail = L"version-unparsable " + installed.version;
    return false;
  }
  if (!(version == metadata.MsixVersionValue())) {
    error = ErrorCode::DeploymentFailedNotInstalled;
    detail = L"registered-version " + installed.version;
    return false;
  }
  if (!installed.status_ok) {
    error = ErrorCode::Indeterminate;
    detail = L"package-status-not-ok";
    return false;
  }
  if (!nh::SamePublisher(installed.publisher, metadata.publisher)) {
    error = ErrorCode::IdentityConflict;
    detail = L"registered-publisher " + installed.publisher;
    return false;
  }
  error = ErrorCode::None;
  return true;
}

}  // namespace planner::installer
