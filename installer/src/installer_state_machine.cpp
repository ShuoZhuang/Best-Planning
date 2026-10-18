#include "installer_state.h"

#include <windows.h>

#include <cstdio>

namespace planner::installer {
namespace {

std::wstring NowUtc() {
  FILETIME now{};
  GetSystemTimeAsFileTime(&now);
  SYSTEMTIME utc{};
  FileTimeToSystemTime(&now, &utc);
  wchar_t buffer[40]{};
  swprintf_s(buffer, L"%04hu-%02hu-%02huT%02hu:%02hu:%02huZ", utc.wYear,
             utc.wMonth, utc.wDay, utc.wHour, utc.wMinute, utc.wSecond);
  return buffer;
}

bool IsOneOf(State state, std::initializer_list<State> states) {
  for (State candidate : states) {
    if (candidate == state) return true;
  }
  return false;
}

}  // namespace

const wchar_t* StateName(State state) {
  switch (state) {
    case State::Initializing:
      return L"INITIALIZING";
    case State::PreflightCheck:
      return L"PREFLIGHT_CHECK";
    case State::Extracting:
      return L"EXTRACTING";
    case State::VerifyingPayload:
      return L"VERIFYING_PAYLOAD";
    case State::RequestingElevation:
      return L"REQUESTING_ELEVATION";
    case State::TrustingCertificate:
      return L"TRUSTING_CERTIFICATE";
    case State::ReVerifyingPayload:
      return L"REVERIFYING_PAYLOAD";
    case State::DeployingPackage:
      return L"DEPLOYING_PACKAGE";
    case State::VerifyingInstallation:
      return L"VERIFYING_INSTALLATION";
    case State::CleaningUp:
      return L"CLEANING_UP";
    case State::Completed:
      return L"COMPLETED";
    case State::Cancelled:
      return L"CANCELLED";
    case State::Blocked:
      return L"BLOCKED";
    case State::FailedBeforeChange:
      return L"FAILED_BEFORE_CHANGE";
    case State::FailedAfterCertificate:
      return L"FAILED_AFTER_CERTIFICATE";
    case State::FailedDuringDeployment:
      return L"FAILED_DURING_DEPLOYMENT";
    case State::FailedAfterDeployment:
      return L"FAILED_AFTER_DEPLOYMENT";
  }
  return L"UNKNOWN";
}

bool IsTerminal(State state) {
  return IsOneOf(state, {State::Completed, State::Cancelled, State::Blocked,
                         State::FailedBeforeChange, State::FailedAfterCertificate,
                         State::FailedDuringDeployment,
                         State::FailedAfterDeployment});
}

bool IsCriticalSection(State state) {
  return IsOneOf(state, {State::TrustingCertificate, State::ReVerifyingPayload,
                         State::DeployingPackage, State::VerifyingInstallation,
                         State::CleaningUp});
}

bool CanTransition(State from, State to) {
  switch (from) {
    case State::Initializing:
      return IsOneOf(to, {State::PreflightCheck, State::Blocked,
                          State::FailedBeforeChange});
    case State::PreflightCheck:
      // `Completed`：当前版本已经是目标版本且用户选择直接启动（规格 §9.6）。
      return IsOneOf(to, {State::Extracting, State::Blocked, State::Completed,
                          State::Cancelled, State::FailedBeforeChange});
    case State::Extracting:
      return IsOneOf(to, {State::VerifyingPayload, State::Cancelled,
                          State::FailedBeforeChange});
    case State::VerifyingPayload:
      // 证书已经受信任时不需要再提权（规格 §8.2：先验证再信任）。
      return IsOneOf(to, {State::RequestingElevation, State::DeployingPackage,
                          State::Cancelled, State::FailedBeforeChange});
    case State::RequestingElevation:
      return IsOneOf(to, {State::TrustingCertificate, State::Cancelled,
                          State::FailedBeforeChange});
    case State::TrustingCertificate:
      return IsOneOf(to, {State::ReVerifyingPayload, State::FailedAfterCertificate});
    case State::ReVerifyingPayload:
      return IsOneOf(to, {State::DeployingPackage, State::FailedAfterCertificate});
    case State::DeployingPackage:
      return IsOneOf(to, {State::VerifyingInstallation,
                          State::FailedDuringDeployment});
    case State::VerifyingInstallation:
      return IsOneOf(to, {State::CleaningUp, State::FailedAfterDeployment});
    case State::CleaningUp:
      return IsOneOf(to, {State::Completed});
    default:
      return false;  // 终止状态不接受任何跳转
  }
}

StateMachine::StateMachine(State initial) : current_(initial) {}

bool StateMachine::MoveTo(State next) {
  if (!CanTransition(current_, next)) return false;
  Transition transition;
  transition.from = current_;
  transition.to = next;
  transition.at_utc = NowUtc();
  history_.push_back(transition);
  current_ = next;
  return true;
}

bool StateMachine::CanCancel() const {
  return IsOneOf(current_, {State::PreflightCheck, State::Extracting,
                            State::VerifyingPayload,
                            State::RequestingElevation});
}

}  // namespace planner::installer
