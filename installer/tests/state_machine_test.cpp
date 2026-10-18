#include "installer_state.h"

#include "test_support.h"

using planner::installer::CanTransition;
using planner::installer::ExitCode;
using planner::installer::IsCriticalSection;
using planner::installer::IsTerminal;
using planner::installer::State;
using planner::installer::StateMachine;

TEST(state_machine_allows_the_documented_chain) {
  StateMachine machine(State::Initializing);
  EXPECT_TRUE(machine.MoveTo(State::PreflightCheck));
  EXPECT_TRUE(machine.MoveTo(State::Extracting));
  EXPECT_TRUE(machine.MoveTo(State::VerifyingPayload));
  EXPECT_TRUE(machine.MoveTo(State::RequestingElevation));
  EXPECT_TRUE(machine.MoveTo(State::TrustingCertificate));
  EXPECT_TRUE(machine.MoveTo(State::ReVerifyingPayload));
  EXPECT_TRUE(machine.MoveTo(State::DeployingPackage));
  EXPECT_TRUE(machine.MoveTo(State::VerifyingInstallation));
  EXPECT_TRUE(machine.MoveTo(State::CleaningUp));
  EXPECT_TRUE(machine.MoveTo(State::Completed));
  EXPECT_TRUE(IsTerminal(State::Completed));
  EXPECT_INT_EQ(10, static_cast<int>(machine.history().size()));
}

TEST(state_machine_rejects_illegal_jumps_without_side_effects) {
  StateMachine machine(State::Initializing);
  EXPECT_FALSE(machine.MoveTo(State::DeployingPackage));
  EXPECT_FALSE(machine.MoveTo(State::Completed));
  EXPECT_INT_EQ(0, static_cast<int>(machine.history().size()));
  EXPECT_TRUE(machine.current() == State::Initializing);

  EXPECT_TRUE(machine.MoveTo(State::PreflightCheck));
  EXPECT_FALSE(machine.MoveTo(State::DeployingPackage));
  EXPECT_FALSE(machine.MoveTo(State::CleaningUp));
  EXPECT_TRUE(machine.current() == State::PreflightCheck);
}

TEST(state_machine_terminal_states_are_final) {
  for (State terminal : {State::Completed, State::Cancelled, State::Blocked,
                         State::FailedBeforeChange,
                         State::FailedAfterCertificate,
                         State::FailedDuringDeployment,
                         State::FailedAfterDeployment}) {
    EXPECT_TRUE(IsTerminal(terminal));
    EXPECT_FALSE(CanTransition(terminal, State::PreflightCheck));
    EXPECT_FALSE(CanTransition(terminal, State::Completed));
  }
}

TEST(state_machine_cancel_points_match_the_spec) {
  StateMachine machine(State::PreflightCheck);
  EXPECT_TRUE(machine.CanCancel());
  EXPECT_TRUE(machine.MoveTo(State::Extracting));
  EXPECT_TRUE(machine.CanCancel());
  EXPECT_TRUE(machine.MoveTo(State::VerifyingPayload));
  EXPECT_TRUE(machine.CanCancel());
  EXPECT_TRUE(machine.MoveTo(State::DeployingPackage));
  EXPECT_FALSE(machine.CanCancel());
  EXPECT_TRUE(machine.MoveTo(State::VerifyingInstallation));
  EXPECT_FALSE(machine.CanCancel());
  EXPECT_TRUE(machine.MoveTo(State::CleaningUp));
  EXPECT_FALSE(machine.CanCancel());
}

TEST(state_machine_marks_critical_sections) {
  EXPECT_TRUE(IsCriticalSection(State::TrustingCertificate));
  EXPECT_TRUE(IsCriticalSection(State::DeployingPackage));
  EXPECT_TRUE(IsCriticalSection(State::VerifyingInstallation));
  EXPECT_FALSE(IsCriticalSection(State::PreflightCheck));
  EXPECT_FALSE(IsCriticalSection(State::Extracting));
}

TEST(state_machine_allows_launch_only_completion) {
  EXPECT_TRUE(CanTransition(State::PreflightCheck, State::Completed));
  EXPECT_TRUE(CanTransition(State::VerifyingPayload, State::DeployingPackage));
  EXPECT_TRUE(CanTransition(State::DeployingPackage, State::FailedDuringDeployment));
  EXPECT_TRUE(CanTransition(State::VerifyingInstallation, State::FailedAfterDeployment));
  EXPECT_FALSE(CanTransition(State::TrustingCertificate, State::Cancelled));
}

TEST(exit_codes_are_the_documented_values) {
  EXPECT_INT_EQ(0, static_cast<int>(ExitCode::Success));
  EXPECT_INT_EQ(10, static_cast<int>(ExitCode::Cancelled));
  EXPECT_INT_EQ(20, static_cast<int>(ExitCode::Unsupported));
  EXPECT_INT_EQ(21, static_cast<int>(ExitCode::AppRunning));
  EXPECT_INT_EQ(30, static_cast<int>(ExitCode::PayloadInvalid));
  EXPECT_INT_EQ(31, static_cast<int>(ExitCode::CertificateFailed));
  EXPECT_INT_EQ(40, static_cast<int>(ExitCode::DeploymentFailedOldPreserved));
  EXPECT_INT_EQ(41, static_cast<int>(ExitCode::DeploymentFailedNotInstalled));
  EXPECT_INT_EQ(42, static_cast<int>(ExitCode::Indeterminate));
  EXPECT_INT_EQ(50, static_cast<int>(ExitCode::LaunchFailed));
  EXPECT_INT_EQ(60, static_cast<int>(ExitCode::DowngradeRejected));
  EXPECT_INT_EQ(70, static_cast<int>(ExitCode::IdentityConflict));
  EXPECT_INT_EQ(99, static_cast<int>(ExitCode::Internal));
}
