#include "installer_controller.h"

#include <shellapi.h>

#include <winrt/Windows.Data.Json.h>

#include <cstdio>

#include "native_shared/planner_identity.h"
#include "native_shared/text.h"
#include "package_verifier.h"
#include "version_generated.h"

#pragma comment(lib, "shell32.lib")

using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;

namespace planner::installer {
namespace {

namespace nh = planner::native;

constexpr wchar_t kInstanceMutex[] = L"Local\\BestPlanningSetup-Instance";
constexpr unsigned kDefaultMinimumWindowsBuild = 17763;

DWORD WindowsBuildNumber() {
  using RtlGetVersionPtr = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE module = GetModuleHandleW(L"ntdll.dll");
  if (module == nullptr) return 0;
  auto function = reinterpret_cast<RtlGetVersionPtr>(
      GetProcAddress(module, "RtlGetVersion"));
  if (function == nullptr) return 0;
  RTL_OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (function(&info) != 0) return 0;
  return info.dwBuildNumber;
}

bool RegistryKeyExists(HKEY root, const wchar_t* subkey) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(root, subkey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  RegCloseKey(key);
  return true;
}

bool PendingReboot() {
  // 只把**真正会阻止服务**的待重启状态算作阻塞（规格 §9.2）。
  // `PendingFileRenameOperations` 在正常使用的电脑上经常有上万条（临时文件、
  // 应用自更新），把它们当成"必须重启"会让几乎所有新用户都装不上——
  // 2026-10-18 在本机实测到 14814 条，而 CBS/WU 都没有待重启标记。
  return RegistryKeyExists(
             HKEY_LOCAL_MACHINE,
             L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Component Based "
             L"Servicing\\RebootPending") ||
         RegistryKeyExists(
             HKEY_LOCAL_MACHINE,
             L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto "
             L"Update\\RebootRequired");
}

std::wstring ActionText(const InstallState& state,
                        const PayloadMetadata& metadata) {
  switch (state.action) {
    case InstallAction::Install:
      return L"将在这台电脑上首次安装优计主义。";
    case InstallAction::Upgrade:
      return L"将从 " + state.package.version + L" 升级到 " +
             metadata.msix_version + L"，任务、课程与设置会被保留。";
    case InstallAction::Repair:
      return L"将重新安装 " + metadata.msix_version + L"（不卸载、不清除数据）。";
    case InstallAction::LaunchOnly:
      return L"当前版本已经是 " + metadata.msix_version + L"。";
    case InstallAction::Blocked:
      return L"这次安装被阻止。";
  }
  return {};
}

}  // namespace

InstallerController::InstallerController(InstallerUi& ui,
                                         std::wstring executable_path)
    : ui_(ui), executable_path_(std::move(executable_path)) {}

InstallerController::~InstallerController() {
  if (instance_mutex_ != nullptr) CloseHandle(instance_mutex_);
}

std::wstring InstallerController::TargetTitle() const {
  return L"优计主义 " + payload_.metadata.app_version;
}

bool InstallerController::MoveTo(State next) {
  const State from = machine_.current();
  if (!machine_.MoveTo(next)) {
    logger_.Failure(L"INSTALLER_STATE_TRANSITION",
                    std::wstring(StateName(from)) + L"->" + StateName(next));
    return false;
  }
  logger_.StateChange(StateName(from), StateName(next));
  return true;
}

void InstallerController::ShowProgress(const std::wstring& status, int percent,
                                       bool indeterminate, bool allow_cancel) {
  UiModel model;
  model.page = UiPage::Progress;
  model.headline = TargetTitle();
  model.subtitle = L"发布者：" + payload_.metadata.publisher;
  model.mode = L"目标版本：" + payload_.metadata.msix_version;
  model.status_line = status;
  model.show_progress = true;
  model.indeterminate_progress = indeterminate;
  model.progress_percent = percent < 0 ? 0 : percent;
  model.secondary_button = L"取消";
  model.secondary_enabled = allow_cancel;
  model.allow_close = false;
  ui_.Present(model);
}

void InstallerController::CleanupSession() {
  if (!session_.created()) return;
  std::wstring error;
  if (!session_.Cleanup(error)) {
    logger_.Line(L"session cleanup failed: " + error);
  }
}

void InstallerController::OpenLog() {
  if (logger_.opened()) {
    ShellExecuteW(nullptr, L"open", logger_.path().c_str(), nullptr, nullptr,
                  SW_SHOWNORMAL);
    return;
  }
  if (!logger_.directory().empty()) {
    ShellExecuteW(nullptr, L"open", logger_.directory().c_str(), nullptr,
                  nullptr, SW_SHOWNORMAL);
  }
}

std::wstring InstallerController::CurrentSystemStateText() {
  std::wstring error;
  planner::native::InstalledPackage installed;
  if (nh::QueryInstalledPackage(payload_.metadata.identity_name, installed,
                                error) &&
      installed.found) {
    return L"这台电脑上仍有优计主义 " + installed.version + L"（没有被移除）。";
  }
  return L"目标版本尚未安装到这台电脑。";
}

void InstallerController::ShowFailurePage(const ErrorDescription& description) {
  UiModel model;
  model.page = UiPage::Failed;
  model.headline = description.title;
  model.subtitle = description.reason;
  model.mode = CurrentSystemStateText();
  model.details = L"建议：" + std::wstring(description.action);
  model.code_line = std::wstring(L"错误编号：") + description.code;
  model.primary_button = L"打开日志";
  model.secondary_button = L"关闭";
  model.allow_close = true;
  if (ui_.Ask(model) == UiDecision::Primary) OpenLog();
}

int InstallerController::Fail(ErrorCode error, const std::wstring& detail) {
  const ErrorDescription description = DescribeError(error);
  logger_.Failure(description.code, detail);

  // 证书回收：只有同时满足规格 §10.2 的条件才删除（且必须有管理员上下文）。
  if (certificate_added_ && !certificate_was_present_ && IsProcessElevated()) {
    std::wstring reason;
    if (CanSafelyRemoveCertificate(payload_.certificate,
                                   certificate_was_present_, reason)) {
      std::wstring remove_error;
      if (RemoveCertificate(payload_.certificate, remove_error)) {
        logger_.Line(L"certificate removed after failure");
      } else {
        logger_.Line(L"certificate removal failed: " + remove_error);
      }
    } else {
      logger_.Line(L"certificate retained: " + reason);
    }
  } else if (certificate_added_) {
    logger_.Line(L"certificate retained: no proof of safety or no admin");
  }

  CleanupSession();

  State terminal = machine_.current();
  const ExitCode code = description.exit;
  State preferred = terminal;
  if (code == ExitCode::Cancelled) {
    preferred = State::Cancelled;
  } else if (code == ExitCode::Unsupported || code == ExitCode::AppRunning ||
             code == ExitCode::DowngradeRejected ||
             code == ExitCode::IdentityConflict ||
             code == ExitCode::Indeterminate) {
    preferred = State::Blocked;
  } else if (!certificate_added_) {
    preferred = State::FailedBeforeChange;
  } else if (machine_.current() == State::DeployingPackage) {
    preferred = State::FailedDuringDeployment;
  } else if (machine_.current() == State::VerifyingInstallation ||
             machine_.current() == State::CleaningUp) {
    preferred = State::FailedAfterDeployment;
  } else {
    preferred = State::FailedAfterCertificate;
  }

  if (preferred != machine_.current() && CanTransition(machine_.current(), preferred)) {
    MoveTo(preferred);
  } else if (!IsTerminal(machine_.current())) {
    for (State candidate : {State::FailedBeforeChange, State::FailedAfterCertificate,
                            State::FailedDuringDeployment,
                            State::FailedAfterDeployment, State::Blocked,
                            State::Cancelled}) {
      if (CanTransition(machine_.current(), candidate)) {
        MoveTo(candidate);
        break;
      }
    }
  }
  logger_.Line(std::wstring(L"result ") + StateName(machine_.current()));

  // 规格 §10.3 的最终状态：基于**系统里实际登记的结果**，不根据异常推断。
  {
    std::wstring query_error;
    planner::native::InstalledPackage installed;
    const bool queried = nh::QueryInstalledPackage(
        payload_.metadata.identity_name, installed, query_error);
    std::wstring final_state;
    if (error == ErrorCode::Indeterminate) {
      final_state = L"Indeterminate";
    } else if (queried && installed.found) {
      final_state = L"PreviousVersionPreserved";
    } else {
      final_state = L"NotInstalled";
    }
    logger_.Line(L"finalState " + final_state);
  }

  ShowFailurePage(description);
  return static_cast<int>(code);
}

bool InstallerController::Preflight(std::wstring& detail, ErrorCode& error) {
  const DWORD build = WindowsBuildNumber();
  const unsigned minimum = payload_.metadata.minimum_windows_build != 0
                               ? payload_.metadata.minimum_windows_build
                               : kDefaultMinimumWindowsBuild;
  if (build != 0 && build < minimum) {
    error = ErrorCode::UnsupportedWindows;
    detail = L"windows-build " + std::to_wstring(build) + L" < " +
             std::to_wstring(minimum);
    return false;
  }

  SYSTEM_INFO system{};
  GetNativeSystemInfo(&system);
  if (system.wProcessorArchitecture != PROCESSOR_ARCHITECTURE_AMD64) {
    error = ErrorCode::UnsupportedArchitecture;
    detail = L"native-architecture " +
             std::to_wstring(system.wProcessorArchitecture);
    return false;
  }

  if (PendingReboot()) {
    error = ErrorCode::PendingRestart;
    detail = L"pending-file-rename";
    return false;
  }

  wchar_t temp[MAX_PATH + 1]{};
  if (GetTempPathW(MAX_PATH, temp) == 0) {
    error = ErrorCode::TempUnavailable;
    detail = L"temp-path";
    return false;
  }
  ULARGE_INTEGER free_bytes{};
  if (GetDiskFreeSpaceExW(temp, nullptr, nullptr, &free_bytes)) {
    const std::uint64_t required =
        payload_.metadata.package_size * 2 + 200ULL * 1024 * 1024;
    if (free_bytes.QuadPart < required) {
      error = ErrorCode::InsufficientDiskSpace;
      detail = L"free " + std::to_wstring(free_bytes.QuadPart) + L" required " +
               std::to_wstring(required);
      return false;
    }
  }

  std::wstring query_error;
  planner::native::InstalledPackage installed;
  if (!nh::QueryInstalledPackage(payload_.metadata.identity_name, installed,
                                 query_error)) {
    error = ErrorCode::PackageManagerUnavailable;
    detail = query_error;
    return false;
  }

  error = ErrorCode::None;
  return true;
}

bool InstallerController::LoadAndExtractPayload(ErrorCode& error,
                                                std::wstring& detail) {
  if (!ReadEmbeddedPayload(payload_, error, detail)) return false;
  std::wstring certificate_error;
  if (!VerifyCertificateMetadata(payload_.metadata, payload_.certificate,
                                 certificate_, error, detail)) {
    return false;
  }
  std::wstring session_error;
  if (!session_.Create(session_error)) {
    error = ErrorCode::TempUnavailable;
    detail = L"session " + session_error;
    return false;
  }
  if (!session_.WriteFile(L"payload.msix", payload_.package.data(),
                          payload_.package.size(), session_error)) {
    error = ErrorCode::TempUnavailable;
    detail = L"extract " + session_error;
    return false;
  }
  payload_path_ = session_.FilePath(L"payload.msix");
  logger_.Line(L"extracted payload bytes=" +
               std::to_wstring(payload_.package.size()));
  return true;
}

bool InstallerController::VerifyExtractedPayload(bool require_trust,
                                                 VerificationOutcome& outcome) {
  outcome = VerifyPayloadFile(payload_.metadata, payload_.certificate,
                              payload_path_, require_trust);
  return outcome.ok;
}

bool InstallerController::EnsureCertificatesKnown(ErrorCode& error,
                                                  std::wstring& detail) {
  bool present = false;
  std::wstring store_error;
  if (!IsTrustedForSideloading(payload_.certificate, present, store_error)) {
    error = ErrorCode::CertificateStoreUnavailable;
    detail = store_error;
    return false;
  }
  certificate_trusted_ = present;
  certificate_was_present_ = present;
  logger_.Line(present ? L"certificate already trusted"
                       : L"certificate not trusted yet");
  error = ErrorCode::None;
  return true;
}

TrustOutcome InstallerController::PerformElevation(const TrustRequest& request) {
  TrustOutcome outcome;
  if (IsProcessElevated()) {
    // 安装器本身已在管理员上下文：直接写入，避免一次无意义的 UAC。
    // 包部署仍由同一个（已是管理员的）用户完成，per-user 语义不变。
    const TrustResult trust = TrustCertificate(payload_.certificate);
    outcome.ok = trust.ok;
    outcome.already_present = trust.already_present;
    outcome.thumbprint = trust.thumbprint;
    outcome.error = trust.ok ? ErrorCode::None : ErrorCode::CertificateImportFailed;
    outcome.detail = trust.error;
    logger_.Line(L"elevation skipped: process already elevated");
    return outcome;
  }
  logger_.Line(L"requesting one elevation for certificate trust");
  ElevationBroker broker(executable_path_);
  return broker.RequestCertificateTrust(request);
}

ErrorCode InstallerController::WaitForApplicationExit() {
  for (;;) {
    DWORD process_id = 0;
    if (!nh::IsPackageRunning(install_state_.package.family_name, process_id)) {
      return ErrorCode::None;
    }
    UiModel model;
    model.page = UiPage::WaitingForAppClose;
    model.headline = L"请先关闭优计主义";
    model.subtitle = L"安装前需要退出正在运行的应用。";
    model.mode = L"检测到应用仍在运行（进程 " +
                 std::to_wstring(process_id) + L"）。";
    model.details =
        L"请保存工作并退出应用（包括托盘图标），然后点“重新检测”。";
    model.primary_button = L"重新检测";
    model.secondary_button = L"取消安装";
    model.allow_close = true;
    const UiDecision decision = ui_.Ask(model);
    if (decision == UiDecision::Primary) continue;
    cancel_requested_.store(true);
    // 明确点"取消安装"是用户取消（10）；直接关闭等待窗口表示应用仍在运行（21）。
    return decision == UiDecision::Secondary ? ErrorCode::Cancelled
                                             : ErrorCode::AppRunning;
  }
}

UiDecision InstallerController::AskPreparation() {
  UiModel model;
  model.page = UiPage::Preparing;
  model.headline = TargetTitle();
  model.subtitle = L"发布者：" + payload_.metadata.publisher;
  model.mode = ActionText(install_state_, payload_.metadata);
  model.details = certificate_was_present_
                      ? L"签名证书已经受信任，不需要再次授权。"
                      : L"安装过程需要一次管理员授权来信任签名证书。";
  model.show_launch_checkbox = true;
  model.launch_checked = true;
  model.primary_button =
      install_state_.action == InstallAction::Upgrade ? L"升级" : L"安装";
  model.secondary_button = L"取消";
  model.allow_close = true;
  return ui_.Ask(model);
}

UiDecision InstallerController::AskSameVersion() {
  UiModel model;
  model.page = UiPage::SameVersion;
  model.headline = L"当前版本已经安装";
  model.subtitle = L"这台电脑上已经安装了 " + install_state_.package.version;
  model.mode = L"安装器版本：" + payload_.metadata.msix_version;
  model.details =
      L"可以启动应用，或重新安装同一版本（不会先卸载，也不会删除数据）。";
  model.primary_button = L"启动优计主义";
  model.secondary_button = L"重新安装";
  model.tertiary_button = L"退出";
  model.allow_close = true;
  return ui_.Ask(model);
}

int InstallerController::ShowCompletion(bool launch_requested, bool launched) {
  UiModel model;
  model.page = UiPage::Completed;
  model.headline = L"安装完成";
  model.subtitle = TargetTitle() + L" 已经安装。";
  model.mode = L"发布者：" + payload_.metadata.publisher;
  model.details = launched
                      ? L"应用已经启动。"
                      : (launch_requested
                             ? L"自动启动没有成功，可以从开始菜单手动打开。"
                             : L"可以从开始菜单打开“优计主义”。");
  model.show_progress = true;
  model.progress_percent = 100;
  model.primary_button = launched ? L"" : L"启动优计主义";
  model.secondary_button = L"完成";
  model.allow_close = true;
  const UiDecision decision = ui_.Ask(model);
  if (decision == UiDecision::Primary) {
    const auto launch = LaunchInstalledApplication(installed_full_name_);
    if (launch.ok) {
      logger_.Line(L"finalState Installed");
      return 0;
    }
    logger_.Line(L"manual launch failed: " + launch.detail);
    logger_.Line(L"finalState InstalledButLaunchFailed");
    ShowFailurePage(DescribeError(ErrorCode::LaunchFailed));
    return static_cast<int>(ExitCode::LaunchFailed);
  }
  if (launched || !launch_requested) {
    logger_.Line(L"finalState Installed");
    return 0;
  }
  logger_.Line(L"installed but auto-launch failed");
  logger_.Line(L"finalState InstalledButLaunchFailed");
  return static_cast<int>(ExitCode::LaunchFailed);
}

int InstallerController::RunInteractive() {
  std::wstring log_error;
  if (!logger_.Open(log_error)) {
    // 日志不可用不阻断安装；失败页会退化为只显示编号。
  }
  logger_.Line(std::wstring(L"setup version ") + APPSETUP_VERSION_WSTRING);

  if (!MoveTo(State::PreflightCheck)) {
    return Fail(ErrorCode::Internal, L"initial-state");
  }

  instance_mutex_ = CreateMutexW(nullptr, TRUE, kInstanceMutex);
  if (instance_mutex_ == nullptr || GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(nullptr, L"安装优计主义");
    if (existing != nullptr) SetForegroundWindow(existing);
    return Fail(ErrorCode::AlreadyRunning, L"second-instance");
  }

  ShowProgress(L"正在检查安装环境…", -1, true, true);
  ErrorCode error = ErrorCode::None;
  std::wstring detail;
  if (!ReadEmbeddedMetadata(payload_.metadata, error, detail)) {
    return Fail(error, detail);
  }
  logger_.Line(L"target " + payload_.metadata.msix_version + L" app " +
               payload_.metadata.app_version);
  if (!Preflight(detail, error)) return Fail(error, detail);
  if (cancel_requested_.load()) return Fail(ErrorCode::Cancelled, L"preflight");
  logger_.Line(L"preflight ok build=" + std::to_wstring(WindowsBuildNumber()));

  if (!QueryInstallState(payload_.metadata, install_state_, error, detail)) {
    return Fail(error, detail);
  }
  if (install_state_.action == InstallAction::Blocked) {
    return Fail(install_state_.publisher_conflict ? ErrorCode::IdentityConflict
                                                  : ErrorCode::DowngradeRejected,
                detail);
  }

  bool repair = false;
  if (install_state_.installed && install_state_.version_is_target) {
    logger_.Line(L"same-version detected " + install_state_.package.version);
    const UiDecision decision = AskSameVersion();
    if (decision == UiDecision::Primary) {
      const auto launch = LaunchInstalledApplication(install_state_.package.full_name);
      if (launch.ok) {
        if (MoveTo(State::Completed)) logger_.Line(L"launch-only completed");
        return 0;
      }
      return Fail(ErrorCode::LaunchFailed, launch.detail);
    }
    if (decision != UiDecision::Secondary) {
      return Fail(ErrorCode::Cancelled, L"same-version-exit");
    }
    repair = true;
    install_state_.action = InstallAction::Repair;
    logger_.Line(L"same-version reinstall requested");
  }

  if (install_state_.installed && install_state_.running) {
    ShowProgress(L"正在等待应用退出…", -1, true, true);
    const ErrorCode wait_result = WaitForApplicationExit();
    if (wait_result != ErrorCode::None) {
      return Fail(wait_result, L"app-running");
    }
  }

  if (!repair) {
    const UiDecision decision = AskPreparation();
    if (decision != UiDecision::Primary) {
      return Fail(ErrorCode::Cancelled, L"preparation");
    }
  }

  if (!MoveTo(State::Extracting)) return Fail(ErrorCode::Internal, L"state");
  ShowProgress(L"正在检查安装包…", -1, true, true);
  if (!LoadAndExtractPayload(error, detail)) return Fail(error, detail);
  if (cancel_requested_.load()) return Fail(ErrorCode::Cancelled, L"extracting");

  if (!MoveTo(State::VerifyingPayload)) return Fail(ErrorCode::Internal, L"state");
  ShowProgress(L"正在检查安装包…", 25, false, true);
  VerificationOutcome outcome;
  if (!VerifyExtractedPayload(false, outcome)) {
    return Fail(outcome.error, outcome.detail);
  }
  logger_.Line(L"payload verified sha256=" + outcome.package_sha256);

  if (!EnsureCertificatesKnown(error, detail)) return Fail(error, detail);

  if (!certificate_trusted_) {
    if (!MoveTo(State::RequestingElevation)) {
      return Fail(ErrorCode::Internal, L"state");
    }
    ShowProgress(L"正在配置安装环境…", -1, true, true);
    if (cancel_requested_.load()) {
      return Fail(ErrorCode::Cancelled, L"elevation");
    }
    const TrustOutcome trust = PerformElevation(
        {payload_.metadata.RawSha256(), payload_.metadata.package_sha256,
         certificate_.thumbprint});
    if (!trust.ok) {
      if (trust.declined) {
        return Fail(ErrorCode::ElevationDeclined, trust.detail);
      }
      if (trust.error == ErrorCode::ElevationResourceMismatch) {
        return Fail(ErrorCode::ElevationResourceMismatch, trust.detail);
      }
      return Fail(ErrorCode::CertificateImportFailed, trust.detail);
    }
    certificate_trusted_ = true;
    certificate_added_ = !trust.already_present;
    if (!MoveTo(State::TrustingCertificate)) {
      return Fail(ErrorCode::Internal, L"state");
    }
    logger_.Line(trust.already_present ? L"certificate already present"
                                       : L"certificate imported");
    if (!MoveTo(State::ReVerifyingPayload)) {
      return Fail(ErrorCode::Internal, L"state");
    }
    ShowProgress(L"正在配置安装环境…", 45, false, false);
    VerificationOutcome reverified;
    if (!VerifyExtractedPayload(true, reverified)) {
      return Fail(reverified.error, reverified.detail);
    }
    logger_.Line(L"payload re-verified with trusted chain");
  } else {
    certificate_added_ = false;
  }

  if (machine_.current() != State::DeployingPackage &&
      !MoveTo(State::DeployingPackage)) {
    return Fail(ErrorCode::Internal, L"state");
  }
  ShowProgress(L"正在安装优计主义…", -1, true, false);
  logger_.Line(repair ? L"deploying (same-version reinstall)"
                      : L"deploying package");
  HRESULT deployment_error = S_OK;
  const bool deployed =
      repair ? ReinstallPackage(payload_path_, deployment_error, error, detail)
             : DeployPackage(payload_path_, deployment_error, error, detail);
  if (!deployed) {
    logger_.Line(L"deployment failed detail " + detail);
    std::wstring verify_detail;
    ErrorCode verify_error = ErrorCode::Internal;
    planner::native::InstalledPackage installed;
    const bool registered =
        VerifyInstalledTarget(payload_.metadata, installed, verify_error,
                              verify_detail);
    if (registered) {
      logger_.Line(L"deployment reported error but target is registered");
    } else if (!installed.found) {
      return Fail(ErrorCode::DeploymentFailedNotInstalled, detail);
    } else if (error == ErrorCode::Indeterminate) {
      return Fail(ErrorCode::Indeterminate, detail);
    } else {
      return Fail(error, detail);
    }
  }

  if (!MoveTo(State::VerifyingInstallation)) {
    return Fail(ErrorCode::Internal, L"state");
  }
  ShowProgress(L"正在验证安装结果…", 85, false, false);
  planner::native::InstalledPackage installed;
  if (!VerifyInstalledTarget(payload_.metadata, installed, error, detail)) {
    return Fail(error, detail);
  }
  installed_full_name_ = installed.full_name;
  logger_.Line(L"installed " + installed.version + L" " + installed.full_name);

  if (!MoveTo(State::CleaningUp)) return Fail(ErrorCode::Internal, L"state");
  ShowProgress(L"正在完成…", 95, false, false);
  CleanupSession();
  if (!MoveTo(State::Completed)) return Fail(ErrorCode::Internal, L"state");
  logger_.Line(L"result Installed version=" + installed.version);

  const bool launch_requested = ui_.LaunchRequested();
  bool launched = false;
  if (launch_requested) {
    const auto launch = LaunchInstalledApplication(installed_full_name_);
    launched = launch.ok;
    logger_.Line(launched ? L"auto-launch ok" : L"auto-launch failed");
    if (!launch.ok) logger_.Line(L"launch detail " + launch.detail);
  }
  return ShowCompletion(launch_requested, launched);
}

int InstallerController::RunPlan() {
  std::wstring log_error;
  logger_.Open(log_error);
  ErrorCode error = ErrorCode::None;
  std::wstring detail;
  JsonObject output;
  int exit_code = 0;

  auto finish = [&output, &exit_code](bool ok, const std::wstring& code,
                                      const std::wstring& detail_text) {
    output.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(ok));
    if (!code.empty()) {
      output.SetNamedValue(L"errorCode", JsonValue::CreateStringValue(code));
    }
    if (!detail_text.empty()) {
      output.SetNamedValue(L"detail", JsonValue::CreateStringValue(detail_text));
    }
    std::printf("%s\n", nh::Utf8FromWide(output.Stringify().c_str()).c_str());
  };

  if (!ReadEmbeddedPayload(payload_, error, detail)) {
    const auto description = DescribeError(error);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, detail);
    return exit_code;
  }
  std::wstring certificate_error;
  if (!VerifyCertificateMetadata(payload_.metadata, payload_.certificate,
                                 certificate_, error, detail)) {
    const auto description = DescribeError(error);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, detail);
    return exit_code;
  }

  std::wstring session_error;
  if (!session_.Create(session_error)) {
    const auto description = DescribeError(ErrorCode::TempUnavailable);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, session_error);
    return exit_code;
  }
  if (!session_.WriteFile(L"payload.msix", payload_.package.data(),
                          payload_.package.size(), session_error)) {
    CleanupSession();
    const auto description = DescribeError(ErrorCode::TempUnavailable);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, session_error);
    return exit_code;
  }
  payload_path_ = session_.FilePath(L"payload.msix");
  VerificationOutcome outcome;
  if (!VerifyExtractedPayload(false, outcome)) {
    CleanupSession();
    const auto description = DescribeError(outcome.error);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, outcome.detail);
    return exit_code;
  }

  bool trusted = false;
  std::wstring store_error;
  IsTrustedForSideloading(payload_.certificate, trusted, store_error);

  if (!QueryInstallState(payload_.metadata, install_state_, error, detail)) {
    CleanupSession();
    const auto description = DescribeError(error);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, detail);
    return exit_code;
  }
  if (install_state_.action == InstallAction::Blocked) {
    CleanupSession();
    const auto description = DescribeError(
        install_state_.publisher_conflict ? ErrorCode::IdentityConflict
                                          : ErrorCode::DowngradeRejected);
    exit_code = static_cast<int>(description.exit);
    finish(false, description.code, detail);
    return exit_code;
  }

  output.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(true));
  output.SetNamedValue(L"targetVersion",
                       JsonValue::CreateStringValue(payload_.metadata.msix_version));
  output.SetNamedValue(L"appVersion",
                       JsonValue::CreateStringValue(payload_.metadata.app_version));
  output.SetNamedValue(L"payloadSha256",
                       JsonValue::CreateStringValue(outcome.package_sha256));
  output.SetNamedValue(L"certificateThumbprint",
                       JsonValue::CreateStringValue(certificate_.thumbprint));
  output.SetNamedValue(L"certificateTrusted",
                       JsonValue::CreateBooleanValue(trusted));
  output.SetNamedValue(
      L"wouldRequestElevation", JsonValue::CreateBooleanValue(!trusted));
  const wchar_t* action = L"install";
  if (install_state_.action == InstallAction::Upgrade) action = L"upgrade";
  if (install_state_.action == InstallAction::Repair) action = L"repair";
  if (install_state_.action == InstallAction::LaunchOnly) action = L"launchOnly";
  output.SetNamedValue(L"action", JsonValue::CreateStringValue(action));
  output.SetNamedValue(L"installedVersion",
                       JsonValue::CreateStringValue(
                           install_state_.installed ? install_state_.package.version
                                                    : L""));
  if (install_state_.installed) {
    // 计划模式只解析 AUMID，不启动任何进程（规格 §8.3：从实际登记结果派生）。
    std::wstring aumid;
    std::wstring aumid_error;
    if (nh::ResolveAumid(install_state_.package.full_name, aumid, aumid_error)) {
      output.SetNamedValue(L"aumid", JsonValue::CreateStringValue(aumid));
    }
  }
  exit_code = 0;
  std::printf("%s\n", nh::Utf8FromWide(output.Stringify().c_str()).c_str());
  CleanupSession();
  return exit_code;
}

int InstallerController::VerifyEmbedded() {
  std::wstring log_error;
  logger_.Open(log_error);
  ErrorCode error = ErrorCode::None;
  std::wstring detail;
  if (!ReadEmbeddedPayload(payload_, error, detail)) {
    const auto description = DescribeError(error);
    std::printf("{\"ok\":false,\"errorCode\":\"%s\"}\n",
                nh::Utf8FromWide(description.code).c_str());
    return static_cast<int>(description.exit);
  }
  std::wstring certificate_error;
  if (!VerifyCertificateMetadata(payload_.metadata, payload_.certificate,
                                 certificate_, error, detail)) {
    const auto description = DescribeError(error);
    std::printf("{\"ok\":false,\"errorCode\":\"%s\",\"detail\":\"%s\"}\n",
                nh::Utf8FromWide(description.code).c_str(),
                nh::Utf8FromWide(detail).c_str());
    return static_cast<int>(description.exit);
  }
  std::wstring session_error;
  if (!session_.Create(session_error) ||
      !session_.WriteFile(L"payload.msix", payload_.package.data(),
                          payload_.package.size(), session_error)) {
    CleanupSession();
    const auto description = DescribeError(ErrorCode::TempUnavailable);
    std::printf("{\"ok\":false,\"errorCode\":\"%s\"}\n",
                nh::Utf8FromWide(description.code).c_str());
    return static_cast<int>(description.exit);
  }
  payload_path_ = session_.FilePath(L"payload.msix");
  VerificationOutcome outcome;
  const bool ok = VerifyExtractedPayload(false, outcome);
  CleanupSession();
  if (!ok) {
    const auto description = DescribeError(outcome.error);
    std::printf("{\"ok\":false,\"errorCode\":\"%s\",\"detail\":\"%s\"}\n",
                nh::Utf8FromWide(description.code).c_str(),
                nh::Utf8FromWide(outcome.detail).c_str());
    return static_cast<int>(description.exit);
  }
  JsonObject output;
  output.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(true));
  output.SetNamedValue(L"targetVersion",
                       JsonValue::CreateStringValue(payload_.metadata.msix_version));
  output.SetNamedValue(L"appVersion",
                       JsonValue::CreateStringValue(payload_.metadata.app_version));
  output.SetNamedValue(L"identityName",
                       JsonValue::CreateStringValue(payload_.metadata.identity_name));
  output.SetNamedValue(L"publisher",
                       JsonValue::CreateStringValue(payload_.metadata.publisher));
  output.SetNamedValue(L"familyName",
                       JsonValue::CreateStringValue(payload_.metadata.family_name));
  output.SetNamedValue(L"packageSha256",
                       JsonValue::CreateStringValue(outcome.package_sha256));
  output.SetNamedValue(L"certificateThumbprint",
                       JsonValue::CreateStringValue(certificate_.thumbprint));
  std::printf("%s\n", nh::Utf8FromWide(output.Stringify().c_str()).c_str());
  return 0;
}

int InstallerController::RunSelfTest() {
  int failures = 0;
  auto check = [&failures](bool condition, const char* name) {
    if (!condition) {
      std::printf("FAIL %s\n", name);
      ++failures;
    }
  };
  // 版本比较与拒绝降级（规格 §16.1）。
  nh::PackageVersion newer;
  nh::PackageVersion older;
  check(nh::PackageVersion::Parse(L"1.10.0.0", newer), "parse version");
  check(nh::PackageVersion::Parse(L"1.9.1.0", older), "parse older version");
  check(newer.IsHigherThan(older), "version ordering");
  check(!older.IsHigherThan(newer), "version ordering is strict");
  check(newer.ToString() == L"1.10.0.0", "version formatting");

  // 状态机：非法跳转必须没有副作用（规格 §9.1）。
  {
    StateMachine machine(State::Initializing);
    check(machine.MoveTo(State::PreflightCheck), "initial -> preflight");
    check(!machine.MoveTo(State::DeployingPackage), "illegal jump rejected");
    check(machine.MoveTo(State::Extracting), "preflight -> extracting");
    check(machine.history().size() == 2, "history recorded");
    check(machine.CanCancel(), "cancel allowed while extracting");
  }
  {
    StateMachine machine(State::DeployingPackage);
    check(!machine.CanCancel(), "cancel forbidden while deploying");
  }

  // 元数据校验：固定身份、发布者、架构、版本与哈希格式。
  {
    PayloadMetadata metadata;
    metadata.schema_version = 1;
    metadata.installer_version = L"1.10.0.0";
    metadata.app_version = L"1.10.0+47";
    metadata.msix_version = L"1.10.0.0";
    metadata.identity_name = nh::kIdentityName;
    metadata.publisher = nh::kPublisher;
    metadata.family_name = nh::PackageFamilyName(nh::kIdentityName, nh::kPublisher);
    metadata.architecture = L"x64";
    metadata.package_size = 1024;
    metadata.package_sha256 = std::wstring(64, L'a');
    metadata.certificate_sha256 = std::wstring(64, L'b');
    metadata.certificate_thumbprint = std::wstring(40, L'c');
    metadata.minimum_windows_build = 17763;
    metadata.asset_file_name = L"BestPlanning_1.10.0.0_x64.msix";
    std::wstring failure;
    check(metadata.Validate(failure), "valid metadata accepted");
    metadata.publisher = L"CN=Someone Else";
    check(!metadata.Validate(failure) &&
              failure == L"INSTALLER_METADATA_PUBLISHER_MISMATCH",
          "publisher mismatch rejected");
    metadata.publisher = nh::kPublisher;
    metadata.architecture = L"arm64";
    check(!metadata.Validate(failure) &&
              failure == L"INSTALLER_METADATA_ARCH_MISMATCH",
          "architecture mismatch rejected");
  }
  // 错误码与退出码映射（规格 §10.4）。
  check(DescribeError(ErrorCode::PayloadHashMismatch).exit ==
            ExitCode::PayloadInvalid,
        "payload exit code");
  check(DescribeError(ErrorCode::CertificateImportFailed).exit ==
            ExitCode::CertificateFailed,
        "certificate exit code");
  check(DescribeError(ErrorCode::DowngradeRejected).exit ==
            ExitCode::DowngradeRejected,
        "downgrade exit code");
  check(DescribeError(ErrorCode::LaunchFailed).exit == ExitCode::LaunchFailed,
        "launch exit code");
  check(ErrorFromStableCode(L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED") ==
            ErrorCode::CertificateUntrusted,
        "stable certificate code");
  check(ErrorFromStableCode(L"INSTALLER_DEPLOY_PACKAGE_IN_USE") ==
            ErrorCode::AppRunning,
        "stable in-use code");

  // 路径与重解析点（规格 §8.4）。
  check(nh::IsPathUnderRoot(L"C:\\Temp\\planner\\payload.msix",
                            L"C:\\Temp\\planner"),
        "path under root");
  check(!nh::IsPathUnderRoot(L"C:\\Temp\\planner\\..\\evil.msix",
                             L"C:\\Temp\\planner"),
        "path traversal rejected");
  check(!nh::IsPathUnderRoot(L"C:\\Other\\payload.msix", L"C:\\Temp\\planner"),
        "sibling path rejected");

  // 证书回收：安装前已存在的证书绝不能删除（规格 §10.2）。
  {
    std::wstring reason;
    check(!CanSafelyRemoveCertificate({}, true, reason),
          "never remove pre-existing certificate");
  }
  // 临时会话：随机目录、排他创建、可清理（规格 §8.4）。
  {
    SecureSession session;
    std::wstring error;
    check(session.Create(error), "session created");
    check(session.WriteFile(L"probe.bin", "ok", 2, error), "session write");
    check(!session.WriteFile(L"probe.bin", "no", 2, error),
          "session refuses to overwrite");
    std::vector<BYTE> read_back;
    check(session.ReadFile(L"probe.bin", read_back, error) &&
              read_back.size() == 2,
          "session read back");
    const std::vector<BYTE> empty_token;
    check(!session.ConsumeToken(empty_token), "empty token rejected");
    const auto token = session.IssueToken();
    check(token.size() == 32, "token size");
    check(session.IssueToken().empty(), "token issued once");
    check(session.ConsumeToken(token), "token accepted once");
    check(!session.ConsumeToken(token), "token is single use");
    check(session.Cleanup(error), "session cleanup");
  }

  if (failures == 0) std::printf("selftest ok\n");
  return failures == 0 ? 0 : 1;
}

}  // namespace planner::installer
