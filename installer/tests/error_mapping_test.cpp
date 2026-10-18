#include <windows.h>

#include <string>

#include "elevation_broker.h"
#include "installer_controller.h"
#include "installer_errors.h"
#include "installer_state.h"
#include "native_shared/deployment_errors.h"
#include "test_support.h"

namespace {

using planner::installer::ControllerTrustError;
using planner::installer::DescribeError;
using planner::installer::ErrorCode;
using planner::installer::ErrorFromStableCode;
using planner::installer::ExitCode;
using planner::installer::TrustOutcome;

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

// ── Task 4：错误传播、界面文案与日志 ─────────────────────────────────────────

TEST(controller_preserves_elevation_failed) {
  TrustOutcome outcome;
  outcome.ok = false;
  outcome.error = ErrorCode::ElevationFailed;
  EXPECT_TRUE(ControllerTrustError(outcome) == ErrorCode::ElevationFailed);

  // UAC 拒绝保留专用分支。
  TrustOutcome declined;
  declined.declined = true;
  declined.error = ErrorCode::ElevationFailed;
  EXPECT_TRUE(ControllerTrustError(declined) == ErrorCode::ElevationDeclined);

  // 资源/摘要不一致原样保留（属于载荷问题，不是证书问题）。
  TrustOutcome mismatch;
  mismatch.error = ErrorCode::ElevationResourceMismatch;
  EXPECT_TRUE(ControllerTrustError(mismatch) ==
              ErrorCode::ElevationResourceMismatch);

  // 内部不变量破坏（ok=false 且 error 仍是 None）才降级。
  TrustOutcome broken;
  broken.ok = false;
  broken.error = ErrorCode::None;
  EXPECT_TRUE(ControllerTrustError(broken) == ErrorCode::ElevationFailed);

  // 成功不产生错误。
  TrustOutcome success;
  success.ok = true;
  success.error = ErrorCode::None;
  EXPECT_TRUE(ControllerTrustError(success) == ErrorCode::None);
}

TEST(controller_preserves_certificate_store_unavailable) {
  TrustOutcome outcome;
  outcome.ok = false;
  outcome.error = ErrorCode::CertificateStoreUnavailable;
  EXPECT_TRUE(ControllerTrustError(outcome) ==
              ErrorCode::CertificateStoreUnavailable);
  EXPECT_TRUE(DescribeError(ErrorCode::CertificateStoreUnavailable).exit ==
              ExitCode::CertificateFailed);
}

TEST(controller_preserves_certificate_import_failed) {
  TrustOutcome outcome;
  outcome.ok = false;
  outcome.error = ErrorCode::CertificateImportFailed;
  EXPECT_TRUE(ControllerTrustError(outcome) ==
              ErrorCode::CertificateImportFailed);
}

TEST(elevation_failed_copy_does_not_claim_certificate_write) {
  const auto description = DescribeError(ErrorCode::ElevationFailed);
  EXPECT_WSTRING_EQ(std::wstring(L"管理员授权步骤未完成"),
                    std::wstring(description.title));
  EXPECT_WSTRING_EQ(
      std::wstring(
          L"安装器启动的管理员辅助进程未能建立安全连接。证书尚未写入，应用尚未安装。"),
      std::wstring(description.reason));
  EXPECT_WSTRING_EQ(std::wstring(L"请重试；如果仍然失败，请打开日志并反馈错误编号。"),
                    std::wstring(description.action));
  EXPECT_TRUE(description.exit == ExitCode::CertificateFailed);

  // "尚未写入"不是"写入失败"：界面不能声称一件尚未发生的事。
  const std::wstring reason(description.reason);
  EXPECT_TRUE(reason.find(L"证书尚未写入") != std::wstring::npos);
  EXPECT_TRUE(reason.find(L"写入失败") == std::wstring::npos);
  EXPECT_TRUE(reason.find(L"导入失败") == std::wstring::npos);
  EXPECT_TRUE(reason.find(L"没能") == std::wstring::npos);
}

TEST(certificate_import_failed_copy_requires_attempted_write) {
  const auto description = DescribeError(ErrorCode::CertificateImportFailed);
  const std::wstring reason(description.reason);
  // 真实的导入失败可以声称"尝试写存储"，但必须与授权阶段失败是不同文案。
  EXPECT_TRUE(reason.find(L"写入") != std::wstring::npos);
  EXPECT_TRUE(reason.find(L"受信任人") != std::wstring::npos);
  EXPECT_FALSE(reason == std::wstring(DescribeError(ErrorCode::ElevationFailed).reason));
  EXPECT_FALSE(std::wstring(description.title) ==
               std::wstring(DescribeError(ErrorCode::ElevationFailed).title));
}
