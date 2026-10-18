// 离线单文件安装器入口（规格 §7.1）。
//
// 同一个 EXE 有两种运行身份：
//   1. 普通权限主进程：界面、校验、一次 UAC、以**发起用户**身份部署、启动；
//   2. 提权辅助进程（`--elevated-session`）：只重读资源、重校验并写一次证书。
//
// 其它子命令（`--verify-embedded` / `--plan` / `--selftest` / `--version`）
// 供发布门禁与诊断使用，都不写系统。
#include <windows.h>
#include <shellapi.h>

#include <winrt/Windows.Foundation.h>

#include <cstdio>
#include <iterator>
#include <string>
#include <vector>

#include "elevation_broker.h"
#include "installer_controller.h"
#include "installer_ui.h"
#include "native_shared/text.h"
#include "version_generated.h"

#pragma comment(lib, "comctl32.lib")

namespace {

std::vector<std::wstring> Arguments() {
  int count = 0;
  LPWSTR* raw = CommandLineToArgvW(GetCommandLineW(), &count);
  std::vector<std::wstring> arguments;
  if (raw == nullptr) return arguments;
  for (int index = 1; index < count; ++index) {
    arguments.emplace_back(raw[index]);
  }
  LocalFree(raw);
  return arguments;
}

std::wstring ExecutablePath() {
  wchar_t buffer[MAX_PATH * 2]{};
  const DWORD length =
      GetModuleFileNameW(nullptr, buffer, static_cast<DWORD>(std::size(buffer)));
  return std::wstring(buffer, length);
}

bool HasFlag(const std::vector<std::wstring>& arguments, const wchar_t* flag) {
  for (const auto& argument : arguments) {
    if (_wcsicmp(argument.c_str(), flag) == 0) return true;
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(HINSTANCE instance, HINSTANCE, LPWSTR, int) {
  const auto arguments = Arguments();
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
  } catch (...) {
    return 99;
  }

  if (HasFlag(arguments, L"--elevated-session")) {
    // 提权辅助进程没有界面，也不初始化对话框。
    return planner::installer::RunElevatedSession(arguments);
  }

  const std::wstring executable = ExecutablePath();
  if (HasFlag(arguments, L"--version")) {
    std::printf("%s\n", planner::native::Utf8FromWide(APPSETUP_VERSION_WSTRING).c_str());
    return 0;
  }

  if (HasFlag(arguments, L"--diagnose")) {
    wchar_t temp[MAX_PATH + 1]{};
    const DWORD length = GetTempPathW(MAX_PATH, temp);
    std::printf("temp length=%lu path=%ls\n", length, temp);
    wchar_t directory[MAX_PATH * 2]{};
    swprintf_s(directory, L"%lsdiag-%lu", temp, GetCurrentProcessId());
    const BOOL created = CreateDirectoryW(directory, nullptr);
    std::printf("mkdir=%d err=%lu\n", created,
                created ? 0 : GetLastError());
    if (created) {
      const std::wstring file = std::wstring(directory) + L"\\probe.txt";
      HANDLE handle = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr,
                                  CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
      std::printf("create file=%d err=%lu\n", handle != INVALID_HANDLE_VALUE,
                  handle == INVALID_HANDLE_VALUE ? GetLastError() : 0);
      if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
      RemoveDirectoryW(directory);
    }
    return 0;
  }

  planner::installer::InstallerUi ui;
  planner::installer::InstallerController controller(ui, executable);

  if (HasFlag(arguments, L"--selftest")) return controller.RunSelfTest();
  if (HasFlag(arguments, L"--verify-embedded")) return controller.VerifyEmbedded();
  if (HasFlag(arguments, L"--plan")) return controller.RunPlan();
  if (HasFlag(arguments, L"--install-unattended")) {
    // 验收/CI：不显示界面，但预检、校验、一次 UAC、部署与验证全部照常执行。
    return ui.RunHeadless([&controller] { return controller.RunInteractive(); },
                          HasFlag(arguments, L"--launch"),
                          HasFlag(arguments, L"--reinstall") ||
                              HasFlag(arguments, L"--repair"));
  }

  return ui.Run(instance, [&controller] { return controller.RunInteractive(); });
}
