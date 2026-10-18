// 安装控制器：唯一的业务编排入口（规格 §7.3、§9）。
//
// 界面只调用控制器；控制器决定状态转换、取消点与系统写入顺序。
#pragma once

#include <windows.h>

#include <atomic>
#include <string>

#include "application_launcher.h"
#include "certificate_manager.h"
#include "elevation_broker.h"
#include "installer_errors.h"
#include "installer_log.h"
#include "installer_state.h"
#include "installer_ui.h"
#include "native_shared/package_deployment.h"
#include "package_deployer.h"
#include "package_verifier.h"
#include "payload_metadata.h"
#include "payload_reader.h"
#include "secure_session.h"

namespace planner::installer {

// 提权结果 → 界面要呈现的错误码（纯函数，不发起 UAC、不写系统）。
//
// 规则（计划 Task 4 Step 3）：UAC 拒绝保留专用分支；资源/摘要不一致原样保留；
// 真实证书写入失败与存储不可用各自保留专有含义；只有"ok=false 但 error 仍是
// None"这种内部不变量破坏才降级为 ElevationFailed。**任何通信失败都不得被改写成
// 证书写入失败**——那会让界面声称一件尚未发生的事。
ErrorCode ControllerTrustError(const TrustOutcome& outcome);

class InstallerController {
 public:
  InstallerController(InstallerUi& ui, std::wstring executable_path);
  ~InstallerController();

  InstallerController(const InstallerController&) = delete;
  InstallerController& operator=(const InstallerController&) = delete;

  int RunInteractive();
  int RunPlan();
  int VerifyEmbedded();
  int RunSelfTest();

  void RequestCancel() { cancel_requested_.store(true); }

 private:
  bool MoveTo(State next);
  bool Preflight(std::wstring& detail, ErrorCode& error);
  bool LoadAndExtractPayload(ErrorCode& error, std::wstring& detail);
  bool VerifyExtractedPayload(bool require_trust, VerificationOutcome& outcome);
  bool EnsureCertificatesKnown(ErrorCode& error, std::wstring& detail);
  ErrorCode WaitForApplicationExit();
  TrustOutcome PerformElevation(const TrustRequest& request);
  int Fail(ErrorCode error, const std::wstring& detail);
  int ShowCompletion(bool launch_requested, bool launched);
  void ShowProgress(const std::wstring& status, int percent,
                    bool indeterminate, bool allow_cancel);
  void ShowFailurePage(const ErrorDescription& description);
  void OpenLog();
  void CleanupSession();
  std::wstring CurrentSystemStateText();
  UiDecision AskPreparation();
  UiDecision AskSameVersion();
  std::wstring TargetTitle() const;

  InstallerUi& ui_;
  std::wstring executable_path_;
  InstallerLogger logger_;
  StateMachine machine_{State::Initializing};
  SecureSession session_;
  EmbeddedPayload payload_;
  CertificateInfo certificate_;
  InstallState install_state_;
  std::atomic<bool> cancel_requested_{false};
  bool certificate_trusted_ = false;
  bool certificate_added_ = false;
  bool certificate_was_present_ = false;
  std::wstring payload_path_;
  std::wstring installed_full_name_;
  HANDLE instance_mutex_ = nullptr;
};

}  // namespace planner::installer
