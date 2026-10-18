// 测试用的"提权辅助进程"替身（计划 §3 新建、Task 1 Step 4）。
//
// 它**不**链接证书写入代码，也不请求管理员权限：只做连接、写一条消息、回显或
// 立即退出这几种行为，用来在真实命名管道上驱动 elevation_channel 的错误分支。
//
// 命令行：
//   --connect <pipeName> [--write <utf8>] [--write-size <bytes>] [--once]
//   --exit <0..255>
//   --sleep <milliseconds>
//
// `--once` 表示写完就退出；缺省时进入"读一条、回写一条"的回显循环，直到对端关闭
// （这样测试结束时不会残留进程）。参数无效返回 2。
#include <windows.h>

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

constexpr DWORD kMessageLimit = 64 * 1024;

BOOL WINAPI ConsoleControl(DWORD) { return FALSE; }

bool WriteMessage(HANDLE pipe, const std::string& payload) {
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (overlapped.hEvent == nullptr) return false;
  DWORD written = 0;
  BOOL ok = WriteFile(pipe, payload.data(), static_cast<DWORD>(payload.size()),
                      &written, &overlapped);
  DWORD status = ok ? ERROR_SUCCESS : GetLastError();
  if (!ok && status == ERROR_IO_PENDING) {
    if (WaitForSingleObject(overlapped.hEvent, 30000) != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &overlapped);
      CloseHandle(overlapped.hEvent);
      return false;
    }
    ok = GetOverlappedResult(pipe, &overlapped, &written, FALSE);
    if (!ok) status = GetLastError();
  }
  CloseHandle(overlapped.hEvent);
  return ok && written == payload.size();
}

// 返回 false 表示对端关闭或 I/O 失败——回显循环据此正常退出。
bool ReadMessage(HANDLE pipe, std::string& payload) {
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (overlapped.hEvent == nullptr) return false;
  std::vector<char> buffer(kMessageLimit);
  DWORD read = 0;
  BOOL ok = ReadFile(pipe, buffer.data(), kMessageLimit, &read, &overlapped);
  DWORD status = ok ? ERROR_SUCCESS : GetLastError();
  if (!ok && status == ERROR_IO_PENDING) {
    if (WaitForSingleObject(overlapped.hEvent, 30000) != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &overlapped);
      CloseHandle(overlapped.hEvent);
      return false;
    }
    ok = GetOverlappedResult(pipe, &overlapped, &read, FALSE);
    if (!ok) status = GetLastError();
  }
  CloseHandle(overlapped.hEvent);
  if (!ok || read == 0) return false;
  payload.assign(buffer.data(), read);
  return true;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetConsoleCtrlHandler(ConsoleControl, TRUE);

  std::wstring pipe_name;
  std::wstring text;
  bool has_text = false;
  size_t text_size = 0;
  bool has_size = false;
  bool once = false;
  bool exit_set = false;
  int exit_code = 0;
  bool sleep_set = false;
  DWORD sleep_ms = 0;

  for (int index = 1; index < argc; ++index) {
    const std::wstring argument = argv[index];
    if (argument == L"--connect" && index + 1 < argc) {
      pipe_name = argv[++index];
    } else if (argument == L"--write" && index + 1 < argc) {
      text = argv[++index];
      has_text = true;
    } else if (argument == L"--write-size" && index + 1 < argc) {
      const long long value = _wtoi64(argv[++index]);
      if (value <= 0 || value > static_cast<long long>(kMessageLimit)) return 2;
      text_size = static_cast<size_t>(value);
      has_size = true;
    } else if (argument == L"--once") {
      once = true;
    } else if (argument == L"--exit" && index + 1 < argc) {
      exit_code = _wtoi(argv[++index]);
      if (exit_code < 0 || exit_code > 255) return 2;
      exit_set = true;
    } else if (argument == L"--sleep" && index + 1 < argc) {
      const long long value = _wtoi64(argv[++index]);
      if (value < 0 || value > 600000) return 2;
      sleep_ms = static_cast<DWORD>(value);
      sleep_set = true;
    } else {
      return 2;
    }
  }

  // 立即退出：用来证明"进程先退出"能被立刻诊断，而不是等到超时。
  if (exit_set) return exit_code;
  if (sleep_set) {
    Sleep(sleep_ms);
    return 0;
  }
  if (pipe_name.empty()) return 2;

  HANDLE pipe = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                            nullptr, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                                SECURITY_IDENTIFICATION,
                            nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return 4;
  {
    DWORD mode = PIPE_READMODE_MESSAGE;
    SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
  }

  std::string payload;
  if (has_size) {
    payload.resize(text_size);
    for (size_t index = 0; index < text_size; ++index) {
      payload[index] = static_cast<char>(index % 251);
    }
  } else if (has_text) {
    const int length = WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, nullptr,
                                          0, nullptr, nullptr);
    if (length > 1) {
      payload.resize(static_cast<size_t>(length - 1));
      WideCharToMultiByte(CP_UTF8, 0, text.c_str(), -1, payload.data(), length - 1,
                          nullptr, nullptr);
    }
  }

  if (!payload.empty() && !WriteMessage(pipe, payload)) {
    CloseHandle(pipe);
    return 4;
  }
  if (once) {
    CloseHandle(pipe);
    return 0;
  }

  // 回显循环：对端关闭即退出，不让测试留下残留进程。
  std::string incoming;
  while (ReadMessage(pipe, incoming)) {
    if (!WriteMessage(pipe, incoming)) break;
  }
  CloseHandle(pipe);
  return 0;
}
