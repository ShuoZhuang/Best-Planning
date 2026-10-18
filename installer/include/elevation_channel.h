// 一次 UAC 会话的命名管道通道（规格 §7.1、§8.1、§8.5）。
//
// 这一层只负责 Win32 事实：管道真正处于 overlapped 模式、等待连接与提权进程
// 同时发生、连接者 PID 由内核给出、有限时长的读写与取消。它**不**含证书业务，
// 也不知道 nonce 与载荷摘要的含义——那些属于 elevation_broker。
//
// 设计约束（不得放宽）：
//   * 服务端 `CreateNamedPipeW` 必须含 `FILE_FLAG_OVERLAPPED`，否则后续传
//     `OVERLAPPED` 的等待与取消没有契约保证；
//   * 两端所有读写都走本文件的有限接口，不混用同步句柄；
//   * 连接者的身份只能来自 `GetNamedPipeClientProcessId`，绝不使用进程树父 PID。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace planner::installer {

// 单条消息硬上限（规格 §2.3）：超过即在写入前拒绝。
inline constexpr DWORD kElevationMessageLimit = 64 * 1024;

// 稳定状态：每个值对应 §2.4 的一条日志/错误语义，不得重命名。
enum class ElevationChannelStatus {
  Connected,
  EventCreationFailed,
  ConnectStartFailed,
  WaitFailed,
  TimedOut,
  ChildExited,
  ClientPidUnavailable,
  ClientPidMismatch,
  IoFailed,
  MessageTooLarge,
};

struct ElevationChannelResult {
  ElevationChannelStatus status = ElevationChannelStatus::ConnectStartFailed;
  DWORD win32_error = ERROR_SUCCESS;
  DWORD child_exit_code = STILL_ACTIVE;
  DWORD expected_client_pid = 0;
  DWORD actual_client_pid = 0;

  bool ok() const { return status == ElevationChannelStatus::Connected; }
};

// 同时等待"管道已连接"与"提权进程已退出"，然后核对实际连接者 PID。
//
// `elevated_process` 为空时只等连接（测试与降级路径）；生产调用必须传入
// `ShellExecuteExW` 返回的进程句柄。
ElevationChannelResult WaitForExpectedElevationClient(
    HANDLE pipe,
    HANDLE elevated_process,
    DWORD expected_client_pid,
    DWORD timeout_ms);

// 读一条消息；`timeout_ms` 内没有完整消息即取消 I/O 并返回 TimedOut。
ElevationChannelResult ReadElevationMessage(
    HANDLE pipe,
    std::string& payload,
    DWORD timeout_ms);

// 写一条消息；超过 kElevationMessageLimit 就在写入前拒绝。
ElevationChannelResult WriteElevationMessage(
    HANDLE pipe,
    const std::string& payload,
    DWORD timeout_ms);

// 稳定状态 token（日志用）：例如 `pipe-client-id-mismatch`。不得含随机 nonce。
const wchar_t* ElevationChannelToken(ElevationChannelStatus status);

// 稳定 detail 文本（§2.4）：只含状态、Win32 错误码与 PID，绝不含随机 nonce。
std::wstring ElevationChannelDetail(const ElevationChannelResult& result,
                                    DWORD timeout_ms = 0);

// 提权辅助进程的命令行：只接受 `--elevated-session --pipe <name> --nonce <hex>`。
//
// 不存在父 PID、证书路径、存储区名称或任意命令字段；重复参数、未知参数、
// pipe 后缀与 nonce 不一致一律拒绝。
struct ElevatedSessionArguments {
  bool valid = false;
  std::wstring pipe_name;
  std::wstring nonce_hex;
  std::wstring error;
};

ElevatedSessionArguments ParseElevatedSessionArguments(
    const std::vector<std::wstring>& arguments);

// 管道名前缀；服务端与解析器共用，避免两处各写一份。
inline constexpr wchar_t kElevationPipePrefix[] =
    L"\\\\.\\pipe\\BestPlanningSetup-";

}  // namespace planner::installer
