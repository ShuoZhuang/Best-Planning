// 真实本地命名管道上的 elevation_channel / 参数解析 / broker 决策测试
// （计划 Task 1 Step 1、Task 2 Step 1、Task 3 Step 1）。
//
// 这些用例不使用 mock：服务端用真实 `CreateNamedPipeW`，客户端是被启动的真实
// 进程 `elevation_test_helper.exe`。helper 的路径由 test_main 传进来（同目录）。
#include <windows.h>

#include <cstring>
#include <string>
#include <vector>

#include "elevation_broker.h"
#include "elevation_channel.h"
#include "installer_errors.h"
#include "test_support.h"

namespace {

using planner::installer::DecideElevationFailure;
using planner::installer::ElevationChannelDetail;
using planner::installer::ElevationChannelResult;
using planner::installer::ElevationChannelStatus;
using planner::installer::ElevatedSessionArguments;
using planner::installer::ErrorCode;
using planner::installer::kElevationMessageLimit;
using planner::installer::MapElevatedResultCode;
using planner::installer::ParseElevatedSessionArguments;
using planner::installer::ReadElevationMessage;
using planner::installer::WaitForExpectedElevationClient;
using planner::installer::WriteElevationMessage;

std::wstring NewPipeName() {
  static LONG counter = 0;
  const LONG id = InterlockedIncrement(&counter);
  wchar_t buffer[128]{};
  swprintf_s(buffer, L"\\\\.\\pipe\\BestPlanningSetupTest-%08lx%08lx%04lx",
             static_cast<unsigned long>(GetCurrentProcessId()),
             static_cast<unsigned long>(GetTickCount()),
             static_cast<unsigned long>(id));
  return buffer;
}

std::wstring HexNonce(wchar_t fill = L'a') { return std::wstring(64, fill); }

std::wstring PipeForNonce(const std::wstring& nonce) {
  return std::wstring(planner::installer::kElevationPipePrefix) + nonce;
}

std::vector<std::wstring> ValidArguments(const std::wstring& nonce) {
  return {L"--elevated-session", L"--pipe", PipeForNonce(nonce), L"--nonce", nonce};
}

// 服务端管道：与生产一致地要求 overlapped + 首实例 + 拒绝远程。
HANDLE CreateServerPipe(const std::wstring& name) {
  SECURITY_ATTRIBUTES attributes{};
  attributes.nLength = sizeof(attributes);
  attributes.bInheritHandle = FALSE;
  return CreateNamedPipeW(
      name.c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1, kElevationMessageLimit, kElevationMessageLimit, 0, &attributes);
}

struct ChildProcess {
  HANDLE process = nullptr;
  DWORD pid = 0;

  ChildProcess() = default;
  ChildProcess(const ChildProcess&) = delete;
  ChildProcess& operator=(const ChildProcess&) = delete;
  ~ChildProcess() {
    if (process != nullptr) {
      WaitForSingleObject(process, 5000);
      CloseHandle(process);
    }
  }

  void Kill() {
    if (process != nullptr) TerminateProcess(process, 0);
  }

  bool Wait(DWORD timeout_ms) {
    return process != nullptr &&
           WaitForSingleObject(process, timeout_ms) == WAIT_OBJECT_0;
  }
};

bool LaunchHelper(const std::wstring& arguments, ChildProcess& child) {
  if (installer_tests::g_helper_path.empty()) return false;
  std::wstring command =
      L"\"" + installer_tests::g_helper_path + L"\" " + arguments;
  std::vector<wchar_t> buffer(command.begin(), command.end());
  buffer.push_back(L'\0');
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION info{};
  if (!CreateProcessW(nullptr, buffer.data(), nullptr, nullptr, FALSE, 0,
                      nullptr, nullptr, &startup, &info)) {
    return false;
  }
  CloseHandle(info.hThread);
  child.process = info.hProcess;
  child.pid = info.dwProcessId;
  return true;
}

bool BytesMatchPattern(const std::string& payload) {
  for (size_t index = 0; index < payload.size(); ++index) {
    if (payload[index] != static_cast<char>(index % 251)) return false;
  }
  return true;
}

// 失败时把状态与 Win32 错误码一起报出来，否则诊断只剩"read.ok() 是假"。
void ExpectChannelOk(const char* file, int line,
                     const ElevationChannelResult& result, const char* what) {
  if (result.ok()) return;
  installer_tests::RecordFailure(
      file, line,
      std::string(what) + " status=" +
          std::to_string(static_cast<int>(result.status)) +
          " win32=" + std::to_string(result.win32_error));
}

}  // namespace

// ── Task 1：overlapped IPC 层 ─────────────────────────────────────────────────

TEST(elevation_channel_connects_expected_client) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  ChildProcess child;
  EXPECT_TRUE(LaunchHelper(L"--connect \"" + name + L"\"", child));
  if (child.process == nullptr) {
    CloseHandle(pipe);
    return;
  }

  const ElevationChannelResult result =
      WaitForExpectedElevationClient(pipe, child.process, child.pid, 5000);
  EXPECT_TRUE(result.ok());
  EXPECT_TRUE(result.status == ElevationChannelStatus::Connected);
  EXPECT_INT_EQ(child.pid, result.actual_client_pid);
  EXPECT_INT_EQ(child.pid, result.expected_client_pid);

  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  EXPECT_TRUE(child.Wait(5000));
}

TEST(elevation_channel_rejects_unexpected_client_pid) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  ChildProcess child;
  EXPECT_TRUE(LaunchHelper(L"--connect \"" + name + L"\"", child));
  if (child.process == nullptr) {
    CloseHandle(pipe);
    return;
  }

  // 故意给一个与真实连接者不同的 PID：内核给出的实际 PID 才是唯一依据。
  const DWORD expected = child.pid == 0xFFFFFFFF ? child.pid - 1 : child.pid + 1;
  const ElevationChannelResult result =
      WaitForExpectedElevationClient(pipe, child.process, expected, 5000);
  EXPECT_FALSE(result.ok());
  EXPECT_TRUE(result.status == ElevationChannelStatus::ClientPidMismatch);
  EXPECT_INT_EQ(expected, result.expected_client_pid);
  EXPECT_INT_EQ(child.pid, result.actual_client_pid);
  // 证据里必须同时保留两个 PID（日志可审计，且不含 nonce）。
  const std::wstring detail = ElevationChannelDetail(result);
  EXPECT_TRUE(detail.find(L"expected=") != std::wstring::npos);
  EXPECT_TRUE(detail.find(L"actual=") != std::wstring::npos);

  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  child.Kill();
  EXPECT_TRUE(child.Wait(5000));
}

TEST(elevation_channel_reports_child_exit_code) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  ChildProcess child;
  EXPECT_TRUE(LaunchHelper(L"--exit 73", child));
  if (child.process == nullptr) {
    CloseHandle(pipe);
    return;
  }

  const ULONGLONG started = GetTickCount64();
  const ElevationChannelResult result =
      WaitForExpectedElevationClient(pipe, child.process, child.pid, 5000);
  const ULONGLONG elapsed = GetTickCount64() - started;
  EXPECT_TRUE(result.status == ElevationChannelStatus::ChildExited);
  EXPECT_INT_EQ(73, result.child_exit_code);
  // 五秒内返回：不得等到三分钟超时，也不得谎报 pipe-connect-timeout。
  EXPECT_TRUE(elapsed < 5000);
  const std::wstring detail = ElevationChannelDetail(result);
  EXPECT_TRUE(detail.find(L"elevated-child-exited exit=73") != std::wstring::npos);
  EXPECT_TRUE(detail.find(L"pipe-connect-timeout") == std::wstring::npos);

  CloseHandle(pipe);
  EXPECT_TRUE(child.Wait(5000));
}

TEST(elevation_channel_times_out_and_cancels_io) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  const ULONGLONG started = GetTickCount64();
  const ElevationChannelResult result =
      WaitForExpectedElevationClient(pipe, nullptr, 1234, 200);
  const ULONGLONG elapsed = GetTickCount64() - started;
  EXPECT_TRUE(result.status == ElevationChannelStatus::TimedOut);
  EXPECT_TRUE(elapsed >= 150);
  EXPECT_TRUE(elapsed < 5000);
  // 只有真正等待超时才允许出现这个 token。
  EXPECT_TRUE(ElevationChannelDetail(result, 200).find(L"pipe-connect-timeout") !=
              std::wstring::npos);

  // 取消已经发生：关闭句柄不会挂起。
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
}

TEST(elevation_channel_round_trips_message_over_overlapped_handles) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  ChildProcess child;
  EXPECT_TRUE(LaunchHelper(L"--connect \"" + name + L"\" --write-size " +
                               std::to_wstring(kElevationMessageLimit),
                           child));
  if (child.process == nullptr) {
    CloseHandle(pipe);
    return;
  }

  const ElevationChannelResult connected =
      WaitForExpectedElevationClient(pipe, child.process, child.pid, 5000);
  EXPECT_TRUE(connected.ok());

  std::string incoming;
  const ElevationChannelResult read =
      ReadElevationMessage(pipe, incoming, 10000);
  ExpectChannelOk(__FILE__, __LINE__, read, "read-64k");
  EXPECT_INT_EQ(static_cast<long long>(kElevationMessageLimit),
                static_cast<long long>(incoming.size()));
  EXPECT_TRUE(BytesMatchPattern(incoming));

  // 反向：服务端写，helper 回显，两端都验证到。
  const ElevationChannelResult wrote =
      WriteElevationMessage(pipe, "{\"ok\":true}", 10000);
  ExpectChannelOk(__FILE__, __LINE__, wrote, "write-ack");
  std::string echo;
  const ElevationChannelResult echoed = ReadElevationMessage(pipe, echo, 10000);
  ExpectChannelOk(__FILE__, __LINE__, echoed, "read-echo");
  EXPECT_TRUE(echo == "{\"ok\":true}");

  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  EXPECT_TRUE(child.Wait(10000));
}

TEST(elevation_channel_rejects_oversized_message) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  const std::string oversized(kElevationMessageLimit + 1, 'x');
  const ElevationChannelResult result =
      WriteElevationMessage(pipe, oversized, 1000);
  EXPECT_TRUE(result.status == ElevationChannelStatus::MessageTooLarge);
  EXPECT_TRUE(ElevationChannelDetail(result).find(L"pipe-message-too-large") !=
              std::wstring::npos);

  CloseHandle(pipe);
}

TEST(elevation_channel_reports_broken_pipe) {
  const std::wstring name = NewPipeName();
  HANDLE pipe = CreateServerPipe(name);
  EXPECT_TRUE(pipe != INVALID_HANDLE_VALUE);
  if (pipe == INVALID_HANDLE_VALUE) return;

  ChildProcess child;
  EXPECT_TRUE(LaunchHelper(
      L"--connect \"" + name + L"\" --write hello --once", child));
  if (child.process == nullptr) {
    CloseHandle(pipe);
    return;
  }

  const ElevationChannelResult connected =
      WaitForExpectedElevationClient(pipe, child.process, child.pid, 5000);
  EXPECT_TRUE(connected.ok());

  std::string incoming;
  const ElevationChannelResult first = ReadElevationMessage(pipe, incoming, 5000);
  ExpectChannelOk(__FILE__, __LINE__, first, "read-hello");
  EXPECT_TRUE(incoming == "hello");

  // helper 已经退出：对端关闭必须在有限时间内报成 IoFailed 并保留 Win32 错误码。
  const ElevationChannelResult second = ReadElevationMessage(pipe, incoming, 5000);
  EXPECT_TRUE(second.status == ElevationChannelStatus::IoFailed);
  EXPECT_TRUE(second.win32_error != ERROR_SUCCESS);

  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  EXPECT_TRUE(child.Wait(5000));
}

// ── Task 2：辅助进程参数与协议绑定 ───────────────────────────────────────────

TEST(elevated_args_accept_exact_pipe_nonce_pair) {
  const std::wstring nonce = HexNonce();
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(ValidArguments(nonce));
  EXPECT_TRUE(parsed.valid);
  EXPECT_TRUE(parsed.error.empty());
  EXPECT_WSTRING_EQ(PipeForNonce(nonce), parsed.pipe_name);
  EXPECT_WSTRING_EQ(nonce, parsed.nonce_hex);
}

TEST(elevated_args_reject_pipe_nonce_mismatch) {
  std::vector<std::wstring> arguments = ValidArguments(HexNonce(L'a'));
  arguments[2] = PipeForNonce(HexNonce(L'b'));
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(arguments);
  EXPECT_FALSE(parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"pipe-nonce-mismatch"), parsed.error);
}

TEST(elevated_args_reject_duplicate_pipe) {
  const std::wstring nonce = HexNonce();
  std::vector<std::wstring> arguments = ValidArguments(nonce);
  arguments.push_back(L"--pipe");
  arguments.push_back(PipeForNonce(nonce));
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(arguments);
  EXPECT_FALSE(parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"duplicate-pipe"), parsed.error);
}

TEST(elevated_args_reject_duplicate_nonce) {
  const std::wstring nonce = HexNonce();
  std::vector<std::wstring> arguments = ValidArguments(nonce);
  arguments.push_back(L"--nonce");
  arguments.push_back(nonce);
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(arguments);
  EXPECT_FALSE(parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"duplicate-nonce"), parsed.error);
}

TEST(elevated_args_reject_parent_argument) {
  const std::wstring nonce = HexNonce();
  std::vector<std::wstring> arguments = ValidArguments(nonce);
  // 旧版的父 PID 参数已经被删除：它现在只是又一个未知参数，没有放行分支。
  arguments.push_back(L"--parent");
  arguments.push_back(L"1234");
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(arguments);
  EXPECT_FALSE(parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"unknown-argument"), parsed.error);
}

TEST(elevated_args_reject_unknown_argument) {
  const std::wstring nonce = HexNonce();
  std::vector<std::wstring> arguments = ValidArguments(nonce);
  arguments.push_back(L"--store");
  arguments.push_back(L"LocalMachine\\Root");
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(arguments);
  EXPECT_FALSE(parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"unknown-argument"), parsed.error);
}

TEST(elevated_args_reject_non_hex_or_wrong_length_nonce) {
  const std::wstring short_nonce(32, L'a');
  const ElevatedSessionArguments short_parsed =
      ParseElevatedSessionArguments(ValidArguments(short_nonce));
  EXPECT_FALSE(short_parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"nonce-format"), short_parsed.error);

  const std::wstring non_hex(64, L'z');
  const ElevatedSessionArguments non_hex_parsed =
      ParseElevatedSessionArguments(ValidArguments(non_hex));
  EXPECT_FALSE(non_hex_parsed.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"nonce-format"), non_hex_parsed.error);

  // 长度对、字符合法，但管道名不匹配时仍然要拒绝。
  const std::wstring good = HexNonce();
  std::vector<std::wstring> arguments = ValidArguments(good);
  arguments[2] = L"\\\\.\\pipe\\Other-" + good;
  const ElevatedSessionArguments wrong_prefix =
      ParseElevatedSessionArguments(arguments);
  EXPECT_FALSE(wrong_prefix.valid);
  EXPECT_WSTRING_EQ(std::wstring(L"pipe-format"), wrong_prefix.error);
}

// ── Task 3：broker 的确定性决策（不发起 UAC、不写系统） ──────────────────────

TEST(broker_maps_child_exit_to_elevation_failed) {
  ElevationChannelResult result;
  result.status = ElevationChannelStatus::ChildExited;
  result.child_exit_code = 3;
  const auto decision = DecideElevationFailure(result, 180000);
  EXPECT_TRUE(decision.error == ErrorCode::ElevationFailed);
  EXPECT_TRUE(decision.detail.find(L"elevated-child-exited exit=3") !=
              std::wstring::npos);
  // 进程已经退出：不得再对它 TerminateProcess。
  EXPECT_FALSE(decision.terminate_helper);
}

TEST(broker_maps_real_timeout_only_to_pipe_connect_timeout) {
  ElevationChannelResult timed_out;
  timed_out.status = ElevationChannelStatus::TimedOut;
  const auto timeout_decision = DecideElevationFailure(timed_out, 180000);
  EXPECT_TRUE(timeout_decision.error == ErrorCode::ElevationFailed);
  EXPECT_TRUE(timeout_decision.detail.find(L"pipe-connect-timeout") !=
              std::wstring::npos);
  EXPECT_TRUE(timeout_decision.detail.find(L"waitMs=180000") !=
              std::wstring::npos);

  for (ElevationChannelStatus status :
       {ElevationChannelStatus::EventCreationFailed,
        ElevationChannelStatus::ConnectStartFailed,
        ElevationChannelStatus::WaitFailed,
        ElevationChannelStatus::IoFailed,
        ElevationChannelStatus::ClientPidUnavailable}) {
    ElevationChannelResult result;
    result.status = status;
    result.win32_error = ERROR_ACCESS_DENIED;
    const auto decision = DecideElevationFailure(result, 180000);
    EXPECT_TRUE(decision.error == ErrorCode::ElevationFailed);
    EXPECT_TRUE(decision.detail.find(L"pipe-connect-timeout") ==
                std::wstring::npos);
  }
}

TEST(broker_rejects_client_pid_mismatch_before_ack) {
  ElevationChannelResult result;
  result.status = ElevationChannelStatus::ClientPidMismatch;
  result.expected_client_pid = 1111;
  result.actual_client_pid = 2222;
  const auto decision = DecideElevationFailure(result, 180000);
  EXPECT_TRUE(decision.error == ErrorCode::ElevationFailed);
  EXPECT_TRUE(decision.detail.find(L"expected=1111") != std::wstring::npos);
  EXPECT_TRUE(decision.detail.find(L"actual=2222") != std::wstring::npos);
  // 握手尚未 ACK：允许终止仍在运行的 helper。
  EXPECT_TRUE(decision.terminate_helper);
}

TEST(broker_preserves_resource_mismatch) {
  EXPECT_TRUE(MapElevatedResultCode(L"INSTALLER_ELEVATION_RESOURCE_MISMATCH") ==
              ErrorCode::ElevationResourceMismatch);
  EXPECT_TRUE(MapElevatedResultCode(L"INSTALLER_ELEVATION_FAILED") ==
              ErrorCode::ElevationFailed);
}

TEST(broker_preserves_certificate_import_failure_after_ack) {
  EXPECT_TRUE(MapElevatedResultCode(L"INSTALLER_CERTIFICATE_IMPORT_FAILED") ==
              ErrorCode::CertificateImportFailed);
  EXPECT_TRUE(MapElevatedResultCode(L"INSTALLER_CERTIFICATE_STORE_UNAVAILABLE") ==
              ErrorCode::CertificateStoreUnavailable);
}

// 握手请求的字段校验（纯函数）：协议版本与摘要不符必须在 ACK 之前停下。
TEST(broker_rejects_handshake_protocol_mismatch) {
  const std::wstring nonce = HexNonce();
  planner::installer::TrustRequest expected;
  expected.metadata_sha256 = std::wstring(64, L'a');
  expected.package_sha256 = std::wstring(64, L'b');
  expected.certificate_thumbprint = std::wstring(40, L'c');

  auto request = [&nonce](int protocol, const std::wstring& metadata) {
    return std::string("{\"protocolVersion\":") + std::to_string(protocol) +
           ",\"nonce\":\"" + installer_tests::Utf8(nonce) + "\"" +
           ",\"command\":\"verify-and-trust-certificate\"" +
           ",\"metadataSha256\":\"" + installer_tests::Utf8(metadata) + "\"" +
           ",\"packageSha256\":\"" + std::string(64, 'b') + "\"" +
           ",\"certificateThumbprint\":\"" + std::string(40, 'c') + "\"}";
  };

  std::wstring field;
  // 协议 1 已不再被接受：同一次 Setup 的主辅进程只说协议 2。
  EXPECT_FALSE(planner::installer::ValidateElevationHandshakeRequest(
      request(1, expected.metadata_sha256), expected, nonce, field));
  EXPECT_WSTRING_EQ(std::wstring(L"protocolVersion"), field);

  field.clear();
  EXPECT_TRUE(planner::installer::ValidateElevationHandshakeRequest(
      request(2, expected.metadata_sha256), expected, nonce, field));
  EXPECT_TRUE(field.empty());
}

TEST(broker_rejects_handshake_digest_mismatch) {
  const std::wstring nonce = HexNonce();
  planner::installer::TrustRequest expected;
  expected.metadata_sha256 = std::wstring(64, L'a');
  expected.package_sha256 = std::wstring(64, L'b');
  expected.certificate_thumbprint = std::wstring(40, L'c');

  const std::string mismatched =
      std::string("{\"protocolVersion\":2,\"nonce\":\"") +
      installer_tests::Utf8(nonce) +
      "\",\"command\":\"verify-and-trust-certificate\","
      "\"metadataSha256\":\"" + std::string(64, 'd') + "\","
      "\"packageSha256\":\"" + std::string(64, 'b') + "\","
      "\"certificateThumbprint\":\"" + std::string(40, 'c') + "\"}";

  std::wstring field;
  EXPECT_FALSE(planner::installer::ValidateElevationHandshakeRequest(
      mismatched, expected, nonce, field));
  EXPECT_WSTRING_EQ(std::wstring(L"metadataSha256"), field);

  // 结构不合法的消息：同样在 ACK 之前拒绝，而不是当成缺省值放行。
  field.clear();
  EXPECT_FALSE(planner::installer::ValidateElevationHandshakeRequest(
      "not-json", expected, nonce, field));
  EXPECT_WSTRING_EQ(std::wstring(L"malformed"), field);
}
