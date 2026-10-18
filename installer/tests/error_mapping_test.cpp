#include <windows.h>

#include <string>

#include "installer_errors.h"
#include "installer_state.h"
#include "native_shared/deployment_errors.h"
#include "test_support.h"

namespace {

using planner::installer::DescribeError;
using planner::installer::ErrorCode;
using planner::installer::ErrorFromStableCode;
using planner::installer::ExitCode;

bool IsDocumentedExit(ExitCode code) {
  switch (code) {
    case ExitCode::Success:
    case ExitCode::Cancelled:
    case ExitCode::Unsupported:
    case ExitCode::AppRunning:
    case ExitCode::PayloadInvalid:
    case ExitCode::CertificateFailed:
    case ExitCode::DeploymentFailedOldPreserved:
    case ExitCode::DeploymentFailedNotInstalled:
    case ExitCode::Indeterminate:
    case ExitCode::LaunchFailed:
    case ExitCode::DowngradeRejected:
    case ExitCode::IdentityConflict:
    case ExitCode::Internal:
      return true;
  }
  return false;
}

}  // namespace

TEST(every_error_code_has_stable_text) {
  const int last = static_cast<int>(ErrorCode::PendingRestart);
  for (int index = 0; index <= last; ++index) {
    const auto description = DescribeError(static_cast<ErrorCode>(index));
    EXPECT_TRUE(description.code != nullptr && description.code[0] != L'\0');
    EXPECT_TRUE(description.title != nullptr && description.title[0] != L'\0');
    EXPECT_TRUE(description.reason != nullptr && description.reason[0] != L'\0');
    EXPECT_TRUE(description.action != nullptr && description.action[0] != L'\0');
    EXPECT_TRUE(IsDocumentedExit(description.exit));
    if (index != 0) {
      EXPECT_FALSE(description.exit == ExitCode::Success);
    }
  }
}

TEST(error_descriptions_match_exit_codes) {
  EXPECT_TRUE(DescribeError(ErrorCode::Cancelled).exit == ExitCode::Cancelled);
  EXPECT_TRUE(DescribeError(ErrorCode::PayloadHashMismatch).exit ==
              ExitCode::PayloadInvalid);
  EXPECT_TRUE(DescribeError(ErrorCode::CertificateImportFailed).exit ==
              ExitCode::CertificateFailed);
  EXPECT_TRUE(DescribeError(ErrorCode::DeploymentFailed).exit ==
              ExitCode::DeploymentFailedOldPreserved);
  EXPECT_TRUE(DescribeError(ErrorCode::DeploymentFailedNotInstalled).exit ==
              ExitCode::DeploymentFailedNotInstalled);
  EXPECT_TRUE(DescribeError(ErrorCode::DowngradeRejected).exit ==
              ExitCode::DowngradeRejected);
  EXPECT_TRUE(DescribeError(ErrorCode::IdentityConflict).exit ==
              ExitCode::IdentityConflict);
  EXPECT_TRUE(DescribeError(ErrorCode::LaunchFailed).exit == ExitCode::LaunchFailed);
  EXPECT_TRUE(DescribeError(ErrorCode::UnsupportedWindows).exit ==
              ExitCode::Unsupported);
  EXPECT_TRUE(DescribeError(ErrorCode::AppRunning).exit == ExitCode::AppRunning);
}

TEST(shared_stable_codes_map_to_installer_errors) {
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_SIGNATURE_MISSING") ==
              ErrorCode::SignatureInvalid);
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_SIGNATURE_INVALID") ==
              ErrorCode::SignatureInvalid);
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED") ==
              ErrorCode::CertificateUntrusted);
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_PUBLISHER_MISMATCH") ==
              ErrorCode::PublisherMismatch);
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_IDENTITY_MISMATCH") ==
              ErrorCode::IdentityMismatch);
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_VERSION_MISMATCH") ==
              ErrorCode::VersionMismatch);
  EXPECT_TRUE(ErrorFromStableCode(L"UPDATE_PACKAGE_ARCH_MISMATCH") ==
              ErrorCode::ArchitectureMismatch);
  EXPECT_TRUE(ErrorFromStableCode(L"INSTALLER_DEPLOY_PACKAGE_IN_USE") ==
              ErrorCode::AppRunning);
  EXPECT_TRUE(ErrorFromStableCode(L"INSTALLER_DEPLOY_DOWNGRADE_REJECTED") ==
              ErrorCode::DowngradeRejected);
  EXPECT_TRUE(ErrorFromStableCode(L"INSTALLER_DEPLOY_CERTIFICATE_UNTRUSTED") ==
              ErrorCode::CertificateUntrusted);
  EXPECT_TRUE(ErrorFromStableCode(L"INSTALLER_DEPLOY_PENDING_RESTART") ==
              ErrorCode::Indeterminate);
  EXPECT_TRUE(ErrorFromStableCode(L"INSTALLER_DEPLOY_FAILED") ==
              ErrorCode::DeploymentFailed);
  EXPECT_TRUE(ErrorFromStableCode(L"") == ErrorCode::Internal);
}

TEST(deployment_errors_have_user_readable_actions) {
  using planner::native::DescribeDeploymentFailure;
  const HRESULT in_use = static_cast<HRESULT>(0x80073D02L);
  const HRESULT untrusted = static_cast<HRESULT>(0x800B0109L);
  const HRESULT downgrade = static_cast<HRESULT>(0x80073D06L);
  const HRESULT pending = static_cast<HRESULT>(0x800700B7L);
  const HRESULT unknown = static_cast<HRESULT>(0x80004005L);

  EXPECT_INT_EQ(21, DescribeDeploymentFailure(in_use).exit_code);
  EXPECT_INT_EQ(31, DescribeDeploymentFailure(untrusted).exit_code);
  EXPECT_INT_EQ(60, DescribeDeploymentFailure(downgrade).exit_code);
  EXPECT_INT_EQ(42, DescribeDeploymentFailure(pending).exit_code);
  EXPECT_INT_EQ(41, DescribeDeploymentFailure(unknown).exit_code);

  for (HRESULT error : {in_use, untrusted, downgrade, pending, unknown}) {
    const auto failure = DescribeDeploymentFailure(error);
    EXPECT_TRUE(failure.code != nullptr && failure.code[0] != L'\0');
    EXPECT_TRUE(failure.reason != nullptr && failure.reason[0] != L'\0');
    EXPECT_TRUE(failure.action != nullptr && failure.action[0] != L'\0');
  }
}

TEST(error_codes_are_distinguishable) {
  // "载荷完整性失败"与"已安装不兼容包"必须是不同错误（规格 §9.7）。
  EXPECT_FALSE(DescribeError(ErrorCode::PayloadHashMismatch).code ==
               DescribeError(ErrorCode::IdentityConflict).code);
  EXPECT_FALSE(DescribeError(ErrorCode::CertificateUntrusted).code ==
               DescribeError(ErrorCode::SignatureInvalid).code);
  EXPECT_FALSE(DescribeError(ErrorCode::DowngradeRejected).code ==
               DescribeError(ErrorCode::DeploymentFailed).code);
}
