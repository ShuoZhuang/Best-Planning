#include "installer_log.h"

#include <windows.h>

#include <algorithm>
#include <cstdio>
#include <vector>

#include "native_shared/text.h"

namespace planner::installer {
namespace {

std::wstring EnvironmentValue(const wchar_t* name) {
  const DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
  if (length == 0) return {};
  std::wstring value(length, L'\0');
  const DWORD written = GetEnvironmentVariableW(name, &value[0], length);
  value.resize(written);
  return value;
}

std::wstring Timestamp(bool for_file_name) {
  SYSTEMTIME utc{};
  GetSystemTime(&utc);
  wchar_t buffer[40]{};
  if (for_file_name) {
    swprintf_s(buffer, L"%04hu%02hu%02hu-%02hu%02hu%02hu", utc.wYear, utc.wMonth,
               utc.wDay, utc.wHour, utc.wMinute, utc.wSecond);
  } else {
    swprintf_s(buffer, L"%04hu-%02hu-%02huT%02hu:%02hu:%02huZ", utc.wYear,
               utc.wMonth, utc.wDay, utc.wHour, utc.wMinute, utc.wSecond);
  }
  return buffer;
}

}  // namespace

InstallerLogger::~InstallerLogger() = default;

bool InstallerLogger::Open(std::wstring& error) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (opened_) return true;
  const std::wstring local = EnvironmentValue(L"LOCALAPPDATA");
  if (local.empty()) {
    error = L"LOCALAPPDATA 不可用";
    return false;
  }
  directory_ = local + L"\\BestPlanning\\Setup";
  std::error_code ignored;
  if (!CreateDirectoryW((local + L"\\BestPlanning").c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    error = L"无法创建日志目录";
    return false;
  }
  if (!CreateDirectoryW(directory_.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS) {
    error = L"无法创建日志目录";
    return false;
  }
  path_ = directory_ + L"\\setup-" + Timestamp(true) + L".log";
  Rotate();
  opened_ = true;
  return true;
}

void InstallerLogger::Rotate() {
  // 只保留最近 10 份日志，避免无限增长。
  WIN32_FIND_DATAW data{};
  HANDLE find = FindFirstFileW((directory_ + L"\\setup-*.log").c_str(), &data);
  if (find == INVALID_HANDLE_VALUE) return;
  std::vector<std::wstring> files;
  do {
    files.push_back(data.cFileName);
  } while (FindNextFileW(find, &data));
  FindClose(find);
  if (files.size() <= 10) return;
  std::sort(files.begin(), files.end());
  for (size_t index = 0; index + 10 < files.size(); ++index) {
    DeleteFileW((directory_ + L"\\" + files[index]).c_str());
  }
}

void InstallerLogger::Line(const std::wstring& text) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (!opened_) return;
  HANDLE file = CreateFileW(path_.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER size{};
  if (GetFileSizeEx(file, &size) && size.QuadPart < 4 * 1024 * 1024) {
    const std::string line =
        planner::native::Utf8FromWide(Timestamp(false) + L" " + text + L"\r\n");
    DWORD written = 0;
    WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written,
              nullptr);
  }
  CloseHandle(file);
}

void InstallerLogger::StateChange(const std::wstring& from,
                                  const std::wstring& to) {
  Line(L"state " + from + L" -> " + to);
}

void InstallerLogger::Failure(const std::wstring& code,
                              const std::wstring& detail) {
  Line(L"failure " + code + (detail.empty() ? L"" : L" detail=" + detail));
}

}  // namespace planner::installer
