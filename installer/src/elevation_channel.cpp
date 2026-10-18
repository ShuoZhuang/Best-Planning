#include "elevation_channel.h"

#include <cstddef>

#include "native_shared/text.h"

namespace planner::installer {
namespace {

namespace nh = planner::native;

// 每次 overlapped 操作独占一个手动复位事件：同步完成、ERROR_IO_PENDING、
// ERROR_PIPE_CONNECTED、超时、等待失败与取消完成都分别处理。
class ManualEvent {
 public:
  ManualEvent() : handle_(CreateEventW(nullptr, TRUE, FALSE, nullptr)) {}
  ~ManualEvent() {
    if (handle_ != nullptr) CloseHandle(handle_);
  }

  ManualEvent(const ManualEvent&) = delete;
  ManualEvent& operator=(const ManualEvent&) = delete;

  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_ = nullptr;
};

const wchar_t* DetailToken(ElevationChannelStatus status) {
  switch (status) {
    case ElevationChannelStatus::Connected:
      return L"pipe-connected";
    case ElevationChannelStatus::EventCreationFailed:
      return L"event-create-failed";
    case ElevationChannelStatus::ConnectStartFailed:
      return L"pipe-connect-start-failed";
    case ElevationChannelStatus::WaitFailed:
      return L"pipe-wait-failed";
    case ElevationChannelStatus::TimedOut:
      return L"pipe-connect-timeout";
    case ElevationChannelStatus::ChildExited:
      return L"elevated-child-exited";
    case ElevationChannelStatus::ClientPidUnavailable:
      return L"pipe-client-id-unavailable";
    case ElevationChannelStatus::ClientPidMismatch:
      return L"pipe-client-id-mismatch";
    case ElevationChannelStatus::IoFailed:
      return L"pipe-io-failed";
    case ElevationChannelStatus::MessageTooLarge:
      return L"pipe-message-too-large";
  }
  return L"pipe-unknown";
}

ElevationChannelResult Failure(ElevationChannelStatus status, DWORD win32_error) {
  ElevationChannelResult result;
  result.status = status;
  result.win32_error = win32_error;
  return result;
}

// "成功"必须显式写成 Connected：默认构造的值是 ConnectStartFailed，用它当成功
// 会让调用方把一次正常读写当成连接失败（这正是本层最容易写错的地方）。
ElevationChannelResult Success(DWORD client_pid = 0) {
  ElevationChannelResult result;
  result.status = ElevationChannelStatus::Connected;
  result.actual_client_pid = client_pid;
  return result;
}

}  // namespace

const wchar_t* ElevationChannelToken(ElevationChannelStatus status) {
  return DetailToken(status);
}

ElevationChannelResult WaitForExpectedElevationClient(HANDLE pipe,
                                                      HANDLE elevated_process,
                                                      DWORD expected_client_pid,
                                                      DWORD timeout_ms) {
  ElevationChannelResult result;
  result.expected_client_pid = expected_client_pid;
  if (pipe == nullptr || pipe == INVALID_HANDLE_VALUE) {
    return Failure(ElevationChannelStatus::ConnectStartFailed,
                   ERROR_INVALID_HANDLE);
  }

  ManualEvent event;
  if (event.get() == nullptr) {
    return Failure(ElevationChannelStatus::EventCreationFailed, GetLastError());
  }

  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  const BOOL started = ConnectNamedPipe(pipe, &overlapped);
  const DWORD status = started ? ERROR_SUCCESS : GetLastError();
  bool connected = false;

  if (status == ERROR_PIPE_CONNECTED) {
    // 客户端在 CreateNamedPipe 与 ConnectNamedPipe 之间就已连上。
    connected = true;
  } else if (started) {
    // 同步完成（非阻塞管道）：已经连上了。
    connected = true;
  } else if (status == ERROR_IO_PENDING) {
    HANDLE handles[2] = {event.get(), elevated_process};
    const DWORD count = elevated_process != nullptr ? 2u : 1u;
    const DWORD wait = WaitForMultipleObjects(count, handles, FALSE, timeout_ms);
    if (wait == WAIT_OBJECT_0) {
      DWORD transferred = 0;
      if (GetOverlappedResult(pipe, &overlapped, &transferred, FALSE)) {
        connected = true;
      } else {
        result = Failure(ElevationChannelStatus::ConnectStartFailed,
                         GetLastError());
      }
    } else if (count == 2 && wait == WAIT_OBJECT_0 + 1) {
      // 提权进程先退出：立即报告真实退出码，不等待三分钟，也不谎报超时。
      CancelIoEx(pipe, &overlapped);
      result.status = ElevationChannelStatus::ChildExited;
      if (!GetExitCodeProcess(elevated_process, &result.child_exit_code)) {
        result.win32_error = GetLastError();
        result.child_exit_code = STILL_ACTIVE;
      }
    } else if (wait == WAIT_TIMEOUT) {
      CancelIoEx(pipe, &overlapped);
      result = Failure(ElevationChannelStatus::TimedOut, ERROR_SUCCESS);
    } else {
      CancelIoEx(pipe, &overlapped);
      result = Failure(ElevationChannelStatus::WaitFailed, GetLastError());
    }
  } else {
    result = Failure(ElevationChannelStatus::ConnectStartFailed, status);
  }

  if (!connected) return result;

  // 连接者身份只来自内核：`GetNamedPipeClientProcessId` 而不是进程树。
  DWORD client_pid = 0;
  if (!GetNamedPipeClientProcessId(pipe, &client_pid)) {
    return Failure(ElevationChannelStatus::ClientPidUnavailable,
                   GetLastError());
  }
  result.actual_client_pid = client_pid;
  if (expected_client_pid == 0 || client_pid != expected_client_pid) {
    result.status = ElevationChannelStatus::ClientPidMismatch;
    return result;
  }
  result.status = ElevationChannelStatus::Connected;
  return result;
}

ElevationChannelResult ReadElevationMessage(HANDLE pipe, std::string& payload,
                                            DWORD timeout_ms) {
  payload.clear();
  if (pipe == nullptr || pipe == INVALID_HANDLE_VALUE) {
    return Failure(ElevationChannelStatus::ConnectStartFailed,
                   ERROR_INVALID_HANDLE);
  }

  ManualEvent event;
  if (event.get() == nullptr) {
    return Failure(ElevationChannelStatus::EventCreationFailed, GetLastError());
  }

  std::vector<char> buffer(kElevationMessageLimit);
  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  DWORD read = 0;
  BOOL ok = ReadFile(pipe, buffer.data(), kElevationMessageLimit, &read,
                     &overlapped);
  DWORD status = ok ? ERROR_SUCCESS : GetLastError();
  if (!ok && status == ERROR_IO_PENDING) {
    const DWORD wait = WaitForSingleObject(event.get(), timeout_ms);
    if (wait == WAIT_OBJECT_0) {
      ok = GetOverlappedResult(pipe, &overlapped, &read, FALSE);
      if (!ok) status = GetLastError();
    } else {
      CancelIoEx(pipe, &overlapped);
      return Failure(wait == WAIT_TIMEOUT ? ElevationChannelStatus::TimedOut
                                         : ElevationChannelStatus::WaitFailed,
                     wait == WAIT_TIMEOUT ? ERROR_SUCCESS : GetLastError());
    }
  }
  if (!ok) return Failure(ElevationChannelStatus::IoFailed, status);
  if (read == 0) {
    // 对端关闭：这是"连接没了"，不是"读到空消息"。
    return Failure(ElevationChannelStatus::IoFailed,
                   status != ERROR_SUCCESS ? status : ERROR_BROKEN_PIPE);
  }
  payload.assign(buffer.data(), read);
  return Success();
}

ElevationChannelResult WriteElevationMessage(HANDLE pipe,
                                            const std::string& payload,
                                            DWORD timeout_ms) {
  if (payload.size() > kElevationMessageLimit) {
    return Failure(ElevationChannelStatus::MessageTooLarge,
                   ERROR_BUFFER_OVERFLOW);
  }
  if (pipe == nullptr || pipe == INVALID_HANDLE_VALUE) {
    return Failure(ElevationChannelStatus::ConnectStartFailed,
                   ERROR_INVALID_HANDLE);
  }

  ManualEvent event;
  if (event.get() == nullptr) {
    return Failure(ElevationChannelStatus::EventCreationFailed, GetLastError());
  }

  OVERLAPPED overlapped{};
  overlapped.hEvent = event.get();
  DWORD written = 0;
  BOOL ok = WriteFile(pipe, payload.data(), static_cast<DWORD>(payload.size()),
                      &written, &overlapped);
  DWORD status = ok ? ERROR_SUCCESS : GetLastError();
  if (!ok && status == ERROR_IO_PENDING) {
    const DWORD wait = WaitForSingleObject(event.get(), timeout_ms);
    if (wait == WAIT_OBJECT_0) {
      ok = GetOverlappedResult(pipe, &overlapped, &written, FALSE);
      if (!ok) status = GetLastError();
    } else {
      CancelIoEx(pipe, &overlapped);
      return Failure(wait == WAIT_TIMEOUT ? ElevationChannelStatus::TimedOut
                                         : ElevationChannelStatus::WaitFailed,
                     wait == WAIT_TIMEOUT ? ERROR_SUCCESS : GetLastError());
    }
  }
  if (!ok) return Failure(ElevationChannelStatus::IoFailed, status);
  if (written != payload.size()) {
    return Failure(ElevationChannelStatus::IoFailed, ERROR_WRITE_FAULT);
  }
  return Success();
}

std::wstring ElevationChannelDetail(const ElevationChannelResult& result,
                                   DWORD timeout_ms) {
  std::wstring detail = ElevationChannelToken(result.status);
  switch (result.status) {
    case ElevationChannelStatus::TimedOut:
      if (timeout_ms != 0) {
        detail += L" waitMs=" + std::to_wstring(timeout_ms);
      }
      break;
    case ElevationChannelStatus::ChildExited:
      detail += L" exit=" + std::to_wstring(result.child_exit_code);
      break;
    case ElevationChannelStatus::ClientPidMismatch:
      detail += L" expected=" + std::to_wstring(result.expected_client_pid) +
                L" actual=" + std::to_wstring(result.actual_client_pid);
      break;
    case ElevationChannelStatus::MessageTooLarge:
      detail += L" limit=" + std::to_wstring(kElevationMessageLimit);
      break;
    case ElevationChannelStatus::Connected:
      detail += L" clientPid=" + std::to_wstring(result.actual_client_pid);
      break;
    default:
      if (result.win32_error != ERROR_SUCCESS) {
        detail += L" win32=" + std::to_wstring(result.win32_error);
      }
      break;
  }
  return detail;
}

ElevatedSessionArguments ParseElevatedSessionArguments(
    const std::vector<std::wstring>& arguments) {
  ElevatedSessionArguments parsed;
  bool session = false;
  bool pipe_seen = false;
  bool nonce_seen = false;
  std::wstring error;

  for (size_t index = 0; index < arguments.size(); ++index) {
    const std::wstring& argument = arguments[index];
    if (_wcsicmp(argument.c_str(), L"--elevated-session") == 0) {
      if (session) {
        error = L"duplicate-session";
        break;
      }
      session = true;
      continue;
    }
    if (_wcsicmp(argument.c_str(), L"--pipe") == 0) {
      if (pipe_seen) {
        error = L"duplicate-pipe";
        break;
      }
      if (index + 1 >= arguments.size()) {
        error = L"missing-pipe-value";
        break;
      }
      pipe_seen = true;
      parsed.pipe_name = arguments[++index];
      continue;
    }
    if (_wcsicmp(argument.c_str(), L"--nonce") == 0) {
      if (nonce_seen) {
        error = L"duplicate-nonce";
        break;
      }
      if (index + 1 >= arguments.size()) {
        error = L"missing-nonce-value";
        break;
      }
      nonce_seen = true;
      parsed.nonce_hex = arguments[++index];
      continue;
    }
    // 除上述两项外一律拒绝：旧版的父 PID 参数、任意路径、证书存储区、脚本都在这里
    // 被当成未知参数挡下——所以生产代码里不存在任何"父进程"放行分支。
    error = L"unknown-argument";
    break;
  }

  if (error.empty() && !session) error = L"missing-session-flag";
  if (error.empty() && !pipe_seen) error = L"missing-pipe";
  if (error.empty() && !nonce_seen) error = L"missing-nonce";
  if (error.empty() && !nh::IsHex(parsed.nonce_hex, 64)) {
    error = L"nonce-format";
  }
  if (error.empty()) {
    const std::wstring prefix(kElevationPipePrefix);
    const bool prefix_ok =
        parsed.pipe_name.size() == prefix.size() + 64 &&
        parsed.pipe_name.compare(0, prefix.size(), prefix) == 0;
    if (!prefix_ok) {
      error = L"pipe-format";
    } else if (_wcsicmp(parsed.pipe_name.c_str() + prefix.size(),
                        parsed.nonce_hex.c_str()) != 0) {
      // 管道后缀必须与 nonce 一字不差；只比长度不算校验。
      error = L"pipe-nonce-mismatch";
    }
  }

  parsed.error = error;
  parsed.valid = error.empty();
  return parsed;
}

}  // namespace planner::installer
