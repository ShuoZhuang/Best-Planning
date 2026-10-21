// 安装状态机（规格 §9.1）。
//
// 每一次转换都必须经过这里：非法跳转直接失败，且**不执行**任何系统写入。
// 取消点也由状态决定（§9.8），界面不得自行判断"现在能不能退出"。
#pragma once

#include <string>
#include <vector>

namespace planner::installer {

enum class State {
  Initializing,
  PreflightCheck,
  Extracting,
  VerifyingPayload,
  RequestingElevation,
  TrustingCertificate,
  ReVerifyingPayload,
  DeployingPackage,
  VerifyingInstallation,
  CleaningUp,
  Completed,
  Cancelled,
  Blocked,
  FailedBeforeChange,
  FailedAfterCertificate,
  FailedDuringDeployment,
  FailedAfterDeployment,
};

const wchar_t* StateName(State state);
bool IsTerminal(State state);
bool IsCriticalSection(State state);
bool CanTransition(State from, State to);

struct Transition {
  State from = State::Initializing;
  State to = State::Initializing;
  std::wstring at_utc;
};

class StateMachine {
 public:
  explicit StateMachine(State initial = State::Initializing);

  bool MoveTo(State next);
  bool CanCancel() const;
  State current() const { return current_; }
  const std::vector<Transition>& history() const { return history_; }

 private:
  State current_;
  std::vector<Transition> history_;
};

// 规格 §10.4 的退出码。
enum class ExitCode : int {
  Success = 0,
  Cancelled = 10,
  Unsupported = 20,
  AppRunning = 21,
  PayloadInvalid = 30,
  CertificateFailed = 31,
  DeploymentFailedOldPreserved = 40,
  DeploymentFailedNotInstalled = 41,
  Indeterminate = 42,
  LaunchFailed = 50,
  DowngradeRejected = 60,
  IdentityConflict = 70,
  Internal = 99,
};

}  // namespace planner::installer
