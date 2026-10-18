// 独立更新助手（规格 §12）。
//
// 它是一个**不联网、不执行命令、只接受更新目录内 `.ready` MSIX** 的原生程序：
//   --probe            输出当前包身份与版本（Dart 侧据此判断"是不是安装包运行"）
//   --verify <msix>    独立读取并验证包（身份、签名、证书链、发布者）
//   --apply <request>  校验一次性请求，等待主程序退出，部署、启动、等待健康确认，失败则回退
//   --selftest         请求校验与路径越界的自检（发布流水线在签名前运行）
//
// 它不解析业务数据：快照只作为不透明文件按清单恢复（§12.4）。
#include <windows.h>
#include <appxpackaging.h>
#include <bcrypt.h>
#include <shobjidl_core.h>

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.Management.Deployment.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <vector>

#include "native_shared/package_inspector.h"
#include "native_shared/planner_identity.h"
#include "native_shared/text.h"

namespace {

namespace nh = planner::native;

using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;
using winrt::Windows::Data::Json::JsonValueType;

constexpr wchar_t kHelperVersion[] = L"1.0.0";
constexpr int kProtocolVersion = 1;
constexpr wchar_t kAumid[] =
    L"ShuoZhuang.PersonalPlanner_v9555qkaxdyym!personalplanner";
constexpr wchar_t kExpectedIdentity[] = L"ShuoZhuang.PersonalPlanner";
constexpr wchar_t kExpectedPublisher[] = L"CN=Shuo Zhuang, O=Personal User, C=CN";
const std::wstring kExpectedFamily =
    nh::PackageFamilyName(kExpectedIdentity, kExpectedPublisher);

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                         0, nullptr, nullptr);
  std::string result(length > 0 ? length - 1 : 0, '\0');
  if (length > 1) {
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), length,
                        nullptr, nullptr);
  }
  return result;
}

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                         0);
  std::wstring result(length > 0 ? length - 1 : 0, L'\0');
  if (length > 1) {
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), length);
  }
  return result;
}

bool WriteAllBytes(const std::wstring& path, const std::string& content) {
  std::ofstream stream(std::filesystem::path(path), std::ios::binary);
  if (!stream) return false;
  stream.write(content.data(), static_cast<std::streamsize>(content.size()));
  stream.flush();
  return stream.good();
}

std::string ReadAllBytes(const std::wstring& path) {
  std::ifstream stream(std::filesystem::path(path), std::ios::binary);
  if (!stream) return {};
  return std::string(std::istreambuf_iterator<char>(stream),
                     std::istreambuf_iterator<char>());
}

std::wstring HResultText(HRESULT value) {
  wchar_t buffer[16]{};
  swprintf_s(buffer, L"0x%08X", static_cast<unsigned int>(value));
  return buffer;
}

// ── 请求 ────────────────────────────────────────────────────────────────────

struct Request {
  int schema_version = 0;
  std::wstring transaction_id;
  std::wstring from_version;
  std::wstring to_version;
  std::wstring package_path;
  std::uint64_t package_size = 0;
  std::wstring package_sha256;
  std::wstring identity_name;
  std::wstring family_name;
  std::wstring publisher;
  std::wstring architecture;
  DWORD main_pid = 0;
  DWORD tray_pid = 0;
  FILETIME main_started{};
  FILETIME tray_started{};
  std::wstring token;
  FILETIME created{};
  FILETIME expires{};
  std::wstring rollback_package_path;
  std::wstring rollback_version;
  std::wstring snapshot_path;
  std::wstring data_directory;
  std::wstring directory;
};

bool ParseIso8601(const std::wstring& value, FILETIME& out) {
  if (value.size() < 19) return false;
  SYSTEMTIME time{};
  if (swscanf_s(value.c_str(), L"%4hu-%2hu-%2huT%2hu:%2hu:%2hu",
                &time.wYear, &time.wMonth, &time.wDay, &time.wHour,
                &time.wMinute, &time.wSecond) != 6) {
    return false;
  }
  time.wMilliseconds = 0;
  return SystemTimeToFileTime(&time, &out) != FALSE;
}

std::uint64_t FileTimeToUint64(const FILETIME& value) {
  ULARGE_INTEGER integer{};
  integer.LowPart = value.dwLowDateTime;
  integer.HighPart = value.dwHighDateTime;
  return integer.QuadPart;
}

std::wstring JsonString(const JsonObject& object, const wchar_t* name,
                        bool required, bool& valid) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::String) {
      if (required) valid = false;
      return {};
    }
    return value.GetString().c_str();
  } catch (...) {
    if (required) valid = false;
    return {};
  }
}

double JsonNumber(const JsonObject& object, const wchar_t* name,
                  double fallback, bool required, bool& valid) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::Number) {
      if (required) valid = false;
      return fallback;
    }
    return value.GetNumber();
  } catch (...) {
    if (required) valid = false;
    return fallback;
  }
}

bool IsHex(const std::wstring& value, size_t length) {
  if (value.size() != length) return false;
  for (wchar_t character : value) {
    const bool hex = (character >= L'0' && character <= L'9') ||
                     (character >= L'a' && character <= L'f') ||
                     (character >= L'A' && character <= L'F');
    if (!hex) return false;
  }
  return true;
}

bool ParseMsixVersion(const std::wstring& value, unsigned& major,
                      unsigned& minor, unsigned& build, unsigned& revision) {
  return swscanf_s(value.c_str(), L"%u.%u.%u.%u", &major, &minor, &build,
                   &revision) == 4;
}

Request ParseRequest(const JsonObject& object, const std::wstring& request_path,
                     std::wstring& failure) {
  Request request;
  bool valid = true;
  request.schema_version = static_cast<int>(
      JsonNumber(object, L"schemaVersion", 0, true, valid));
  request.transaction_id = JsonString(object, L"transactionId", true, valid);
  request.from_version = JsonString(object, L"fromVersion", true, valid);
  request.to_version = JsonString(object, L"toVersion", true, valid);
  request.package_path = JsonString(object, L"packagePath", true, valid);
  request.package_size = static_cast<std::uint64_t>(
      JsonNumber(object, L"packageSizeBytes", 0, true, valid));
  request.package_sha256 = JsonString(object, L"packageSha256", true, valid);
  request.identity_name = JsonString(object, L"identityName", true, valid);
  request.family_name = JsonString(object, L"familyName", true, valid);
  request.publisher = JsonString(object, L"publisher", true, valid);
  request.architecture = JsonString(object, L"architecture", true, valid);
  request.main_pid = static_cast<DWORD>(
      JsonNumber(object, L"mainPid", 0, false, valid));
  request.tray_pid = static_cast<DWORD>(
      JsonNumber(object, L"trayPid", 0, false, valid));
  request.token = JsonString(object, L"token", true, valid);
  request.rollback_package_path =
      JsonString(object, L"rollbackPackagePath", false, valid);
  request.rollback_version = JsonString(object, L"rollbackVersion", false, valid);
  request.snapshot_path = JsonString(object, L"snapshotPath", false, valid);
  request.data_directory = JsonString(object, L"dataDirectory", false, valid);

  if (!ParseIso8601(JsonString(object, L"mainStartedAtUtc", true, valid),
                    request.main_started) ||
      !ParseIso8601(JsonString(object, L"createdAtUtc", true, valid),
                    request.created) ||
      !ParseIso8601(JsonString(object, L"expiresAtUtc", true, valid),
                    request.expires)) {
    valid = false;
  }
  const auto tray_started =
      JsonString(object, L"trayStartedAtUtc", false, valid);
  if (!tray_started.empty() && !ParseIso8601(tray_started, request.tray_started)) {
    valid = false;
  }

  request.directory = std::filesystem::path(request_path).parent_path().wstring();
  const std::wstring update_root =
      std::filesystem::path(request.directory).parent_path().wstring();

  if (!valid) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (request.schema_version != 1) {
    failure = L"UPDATE_HELPER_VERSION_INCOMPATIBLE";
    return request;
  }
  if (request.transaction_id.empty() || request.transaction_id.size() > 64) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  unsigned a = 0, b = 0, c = 0, d = 0;
  if (!ParseMsixVersion(request.from_version, a, b, c, d) ||
      !ParseMsixVersion(request.to_version, a, b, c, d)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (request.to_version == request.from_version) {
    failure = L"UPDATE_PACKAGE_VERSION_SAME";
    return request;
  }
  if (!IsHex(request.package_sha256, 64) || request.package_size == 0) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (request.identity_name != kExpectedIdentity ||
      request.family_name != kExpectedFamily ||
      request.publisher != kExpectedPublisher) {
    failure = L"UPDATE_PACKAGE_IDENTITY_MISMATCH";
    return request;
  }
  if (request.architecture != L"x64") {
    failure = L"UPDATE_PACKAGE_ARCH_MISMATCH";
    return request;
  }
  if (!IsHex(request.token, 64)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (!nh::IsPathUnderRoot(request.package_path, update_root)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  const auto extension = std::filesystem::path(request.package_path)
                             .extension()
                             .wstring();
  if (extension != L".ready") {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (!request.rollback_package_path.empty() &&
      !nh::IsPathUnderRoot(request.rollback_package_path,
                                      update_root)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (!request.snapshot_path.empty() &&
      !nh::IsPathUnderRoot(request.snapshot_path, update_root)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (FileTimeToUint64(request.expires) <= FileTimeToUint64(request.created)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  FILETIME now{};
  GetSystemTimeAsFileTime(&now);
  // 有效期上限 15 分钟：请求文件不应在磁盘上长期有效。
  if (FileTimeToUint64(request.expires) - FileTimeToUint64(request.created) >
      15ULL * 60 * 10000000) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  if (FileTimeToUint64(now) > FileTimeToUint64(request.expires)) {
    failure = L"UPDATE_HELPER_REQUEST_INVALID";
    return request;
  }
  return request;
}

// ── 状态文件 ────────────────────────────────────────────────────────────────

void WriteStatus(const std::wstring& directory,
                 const std::wstring& transaction_id, const std::wstring& state,
                 const std::wstring& failure_code = {},
                 int hresult = 0) {
  JsonObject object;
  object.SetNamedValue(L"schemaVersion", JsonValue::CreateNumberValue(1));
  object.SetNamedValue(L"transactionId",
                       JsonValue::CreateStringValue(transaction_id));
  object.SetNamedValue(L"state", JsonValue::CreateStringValue(state));
  object.SetNamedValue(L"helperPid",
                       JsonValue::CreateNumberValue(GetCurrentProcessId()));
  FILETIME now{};
  GetSystemTimeAsFileTime(&now);
  SYSTEMTIME utc{};
  FileTimeToSystemTime(&now, &utc);
  wchar_t timestamp[64]{};
  swprintf_s(timestamp, L"%04hu-%02hu-%02huT%02hu:%02hu:%02huZ", utc.wYear,
             utc.wMonth, utc.wDay, utc.wHour, utc.wMinute, utc.wSecond);
  object.SetNamedValue(L"updatedAtUtc",
                       JsonValue::CreateStringValue(timestamp));
  if (!failure_code.empty()) {
    object.SetNamedValue(L"failureCode",
                         JsonValue::CreateStringValue(failure_code));
  }
  if (hresult != 0) {
    object.SetNamedValue(L"hresult",
                         JsonValue::CreateStringValue(HResultText(hresult)));
  }
  WriteAllBytes(directory + L"\\helper-status.json",
                Utf8(object.Stringify().c_str()));
}

// ── 进程协调 ────────────────────────────────────────────────────────────────

bool ProcessMatchesStartTime(DWORD pid, const FILETIME& expected) {
  if (pid == 0) return false;
  HANDLE process = OpenProcess(
      PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, pid);
  if (process == nullptr) return false;
  FILETIME creation{}, exit{}, kernel{}, user{};
  const bool has_times =
      GetProcessTimes(process, &creation, &exit, &kernel, &user) != FALSE;
  CloseHandle(process);
  if (!has_times) return false;
  const std::uint64_t actual = FileTimeToUint64(creation);
  const std::uint64_t wanted = FileTimeToUint64(expected);
  const std::uint64_t difference =
      actual > wanted ? actual - wanted : wanted - actual;
  // 允许 2 秒误差：Dart 侧通过 FFI 读取的时间与这里来自同一个系统时钟。
  return difference <= 2ULL * 10000000;
}

bool WaitForProcessExit(DWORD pid, const FILETIME& expected, int timeout_ms) {
  if (!ProcessMatchesStartTime(pid, expected)) return true;  // 已经退出或 PID 被复用
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  while (GetTickCount64() < deadline) {
    if (!ProcessMatchesStartTime(pid, expected)) return true;
    Sleep(200);
  }
  return !ProcessMatchesStartTime(pid, expected);
}

// ── 部署与启动 ──────────────────────────────────────────────────────────────

std::wstring FileUri(const std::wstring& path) {
  std::wstring uri = L"file:///";
  for (wchar_t character : path) {
    uri.push_back(character == L'\\' ? L'/' : character);
  }
  return uri;
}

bool DeployPackage(const std::wstring& path, int& hresult,
                   std::wstring& detail, bool allow_downgrade = false) {
  using winrt::Windows::Foundation::Uri;
  using namespace winrt::Windows::Management::Deployment;
  try {
    PackageManager manager;
    const auto dependencies =
        winrt::single_threaded_vector<winrt::Windows::Foundation::Uri>();
    const auto operation = manager.AddPackageAsync(
        Uri(winrt::hstring(FileUri(path))), dependencies,
        allow_downgrade
            ? (DeploymentOptions::ForceUpdateFromAnyVersion |
               DeploymentOptions::ForceApplicationShutdown)
            : DeploymentOptions::None);
    const auto result = operation.get();
    if (result.IsRegistered()) return true;
    hresult = result.ExtendedErrorCode();
    detail = result.ErrorText().c_str();
    return false;
  } catch (const winrt::hresult_error& error) {
    hresult = error.code();
    detail = error.message().c_str();
    return false;
  } catch (...) {
    hresult = E_UNEXPECTED;
    return false;
  }
}

bool ActivateApp(DWORD& process_id) {
  IApplicationActivationManager* manager = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_ApplicationActivationManager, nullptr,
                                CLSCTX_LOCAL_SERVER,
                                IID_PPV_ARGS(&manager));
  if (FAILED(hr)) return false;
  hr = manager->ActivateApplication(kAumid, nullptr, AO_NONE, &process_id);
  manager->Release();
  return SUCCEEDED(hr);
}

// ── 健康确认 ────────────────────────────────────────────────────────────────

bool ConfirmationAccepted(const std::wstring& path,
                          const std::wstring& transaction_id,
                          const std::wstring& version) {
  const auto content = ReadAllBytes(path);
  if (content.empty()) return false;
  try {
    const auto object = JsonObject::Parse(Wide(content));
    if (object.GetNamedString(L"transactionId").c_str() != transaction_id) {
      return false;
    }
    if (object.GetNamedBoolean(L"ok", false) != true) return false;
    return object.GetNamedString(L"version").c_str() == version;
  } catch (...) {
    return false;
  }
}

std::uint64_t FileModifiedTicks(const std::wstring& path) {
  WIN32_FILE_ATTRIBUTE_DATA data{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &data)) {
    return 0;
  }
  return FileTimeToUint64(data.ftLastWriteTime);
}

bool WaitForHealth(const Request& request) {
  const std::wstring confirmation = request.directory +
                                    L"\\health-confirmation.json";
  const std::wstring progress = request.directory + L"\\health-progress.json";
  const ULONGLONG start = GetTickCount64();
  std::uint64_t progress_marker = FileModifiedTicks(progress);
  ULONGLONG last_heartbeat = 0;
  while (true) {
    if (ConfirmationAccepted(confirmation, request.transaction_id,
                             request.to_version)) {
      return true;
    }
    const ULONGLONG elapsed = GetTickCount64() - start;
    const std::uint64_t current = FileModifiedTicks(progress);
    if (current != 0 && current != progress_marker) {
      progress_marker = current;
      last_heartbeat = elapsed;
    }
    const bool heartbeat_recent =
        last_heartbeat > 0 && elapsed - last_heartbeat <= 15000;
    // 初始 60 秒；新版本每 10 秒心跳可延长，但绝对上限 5 分钟。
    if (elapsed > 60000 && !heartbeat_recent) return false;
    if (elapsed > 300000) return false;
    Sleep(500);
  }
}

// ── 回退 ────────────────────────────────────────────────────────────────────

bool RestoreSnapshot(const std::wstring& snapshot_path,
                     const std::wstring& data_directory,
                     std::wstring& detail) {
  const std::wstring manifest_path =
      snapshot_path + L"\\snapshot-manifest.json";
  const auto content = ReadAllBytes(manifest_path);
  if (content.empty() || data_directory.empty()) return false;
  try {
    const auto object = JsonObject::Parse(Wide(content));
    const auto files = object.GetNamedArray(L"files");
    for (uint32_t index = 0; index < files.Size(); ++index) {
      const auto entry = files.GetObjectAt(index);
      const std::wstring relative = entry.GetNamedString(L"relative").c_str();
      const std::wstring source =
          snapshot_path + L"\\" + relative;
      const std::wstring target = data_directory + L"\\" + relative;
      std::filesystem::create_directories(
          std::filesystem::path(target).parent_path());
      std::error_code error;
      std::filesystem::copy_file(source, target,
                                 std::filesystem::copy_options::overwrite_existing,
                                 error);
      if (error) {
        detail = Wide(error.message());
        return false;
      }
    }
    return true;
  } catch (...) {
    return false;
  }
}

bool RollBack(const Request& request, std::wstring& failure_code,
              int& rollback_hresult) {
  rollback_hresult = 0;
  if (request.rollback_package_path.empty() ||
      request.snapshot_path.empty()) {
    failure_code = L"UPDATE_ROLLBACK_PACKAGE_MISSING";
    return false;
  }
  if (!std::filesystem::exists(request.rollback_package_path)) {
    failure_code = L"UPDATE_ROLLBACK_PACKAGE_MISSING";
    return false;
  }
  int hresult = 0;
  std::wstring detail;
  if (!DeployPackage(request.rollback_package_path, hresult, detail, true)) {
    failure_code = L"UPDATE_ROLLBACK_DEPLOYMENT_FAILED";
    rollback_hresult = hresult;
    return false;
  }
  if (!RestoreSnapshot(request.snapshot_path, request.data_directory, detail)) {
    failure_code = L"UPDATE_ROLLBACK_DATA_RESTORE_FAILED";
    return false;
  }
  DWORD pid = 0;
  if (!ActivateApp(pid)) {
    failure_code = L"UPDATE_ROLLBACK_DEPLOYMENT_FAILED";
    return false;
  }
  failure_code = L"UPDATE_ROLLBACK_SUCCEEDED";
  return true;
}

// ── 助手锁 ──────────────────────────────────────────────────────────────────

struct HelperLock {
  HANDLE handle = INVALID_HANDLE_VALUE;
  std::wstring path;

  ~HelperLock() {
    if (handle != INVALID_HANDLE_VALUE) {
      CloseHandle(handle);
      DeleteFileW(path.c_str());
    }
  }

  bool Acquire(const std::wstring& directory,
               const std::wstring& transaction_id) {
    path = directory + L"\\update-helper.lock";
    handle = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle == INVALID_HANDLE_VALUE) {
      // 陈旧锁：内容里的 PID 已不存活时删除后重试一次。
      const auto existing = ReadAllBytes(path);
      if (!existing.empty()) {
        try {
          const auto object = JsonObject::Parse(Wide(existing));
          const DWORD pid = static_cast<DWORD>(
              object.GetNamedNumber(L"pid", 0));
          if (pid == 0) return false;
          HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                       pid);
          if (process != nullptr) {
            CloseHandle(process);
            return false;
          }
        } catch (...) {
          return false;
        }
      }
      DeleteFileW(path.c_str());
      handle = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
      if (handle == INVALID_HANDLE_VALUE) return false;
    }
    JsonObject object;
    object.SetNamedValue(L"pid",
                         JsonValue::CreateNumberValue(GetCurrentProcessId()));
    object.SetNamedValue(L"transactionId",
                         JsonValue::CreateStringValue(transaction_id));
    const std::string content = Utf8(object.Stringify().c_str());
    DWORD written = 0;
    WriteFile(handle, content.data(), static_cast<DWORD>(content.size()),
              &written, nullptr);
    FlushFileBuffers(handle);
    return true;
  }
};

// ── 子命令 ──────────────────────────────────────────────────────────────────

int RunProbe() {
  nh::PackageIdentity identity;
  const bool packaged = nh::CurrentPackageIdentity(identity);
  JsonObject object;
  object.SetNamedValue(L"helperVersion",
                       JsonValue::CreateStringValue(kHelperVersion));
  object.SetNamedValue(L"protocolVersion",
                       JsonValue::CreateNumberValue(kProtocolVersion));
  if (packaged) {
    JsonObject package;
    package.SetNamedValue(L"identityName",
                          JsonValue::CreateStringValue(identity.name));
    package.SetNamedValue(L"publisher",
                          JsonValue::CreateStringValue(identity.publisher));
    package.SetNamedValue(L"familyName",
                          JsonValue::CreateStringValue(identity.family_name));
    package.SetNamedValue(L"architecture",
                          JsonValue::CreateStringValue(identity.architecture));
    package.SetNamedValue(
        L"version", JsonValue::CreateStringValue(identity.VersionString()));
    package.SetNamedValue(L"isPackaged", JsonValue::CreateBooleanValue(true));
    object.SetNamedValue(L"installedPackage", package);
  } else {
    object.SetNamedValue(L"installedPackage", JsonValue::CreateNullValue());
  }
  std::printf("%s\n", Utf8(object.Stringify().c_str()).c_str());
  return 0;
}

int RunVerify(const std::wstring& path) {
  const auto inspection = nh::InspectPackage(path, nh::SignatureCheck::TrustedChain);
  JsonObject object;
  object.SetNamedValue(L"ok",
                       JsonValue::CreateBooleanValue(inspection.ok));
  if (!inspection.ok) {
    object.SetNamedValue(
        L"failureCode", JsonValue::CreateStringValue(inspection.failure_code));
    if (!inspection.detail.empty()) {
      object.SetNamedValue(L"detail",
                           JsonValue::CreateStringValue(inspection.detail));
    }
  } else {
    JsonObject identity;
    identity.SetNamedValue(
        L"identityName", JsonValue::CreateStringValue(inspection.identity.name));
    identity.SetNamedValue(
        L"publisher", JsonValue::CreateStringValue(inspection.identity.publisher));
    identity.SetNamedValue(
        L"familyName", JsonValue::CreateStringValue(inspection.identity.family_name));
    identity.SetNamedValue(
        L"architecture",
        JsonValue::CreateStringValue(inspection.identity.architecture));
    identity.SetNamedValue(
        L"version",
        JsonValue::CreateStringValue(inspection.identity.VersionString()));
    object.SetNamedValue(L"identity", identity);
    std::vector<BYTE> digest;
    if (nh::Sha256File(path, digest)) {
      std::wstring hex;
      for (BYTE byte : digest) {
        wchar_t piece[3]{};
        swprintf_s(piece, L"%02x", byte);
        hex += piece;
      }
      object.SetNamedValue(L"sha256", JsonValue::CreateStringValue(hex));
    }
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    if (!error) {
      object.SetNamedValue(
          L"sizeBytes", JsonValue::CreateNumberValue(
                            static_cast<double>(size)));
    }
  }
  std::printf("%s\n", Utf8(object.Stringify().c_str()).c_str());
  return inspection.ok ? 0 : 2;
}

int RunApply(const std::wstring& request_path, bool dry_run = false) {
  const std::wstring directory =
      std::filesystem::path(request_path).parent_path().wstring();
  std::wstring failure;
  Request request;
  try {
    const auto content = ReadAllBytes(request_path);
    if (content.empty()) {
      WriteStatus(directory, L"", L"failed", L"UPDATE_HELPER_REQUEST_INVALID");
      return 2;
    }
    const auto object = JsonObject::Parse(Wide(content));
    request = ParseRequest(object, request_path, failure);
  } catch (...) {
    WriteStatus(directory, L"", L"failed", L"UPDATE_HELPER_REQUEST_INVALID");
    return 2;
  }
  if (!failure.empty()) {
    WriteStatus(directory, request.transaction_id, L"failed", failure);
    return 2;
  }

  // 一次性：消费请求文件，重复调用会找不到它。
  const std::wstring consumed = request_path + L".consumed";
  MoveFileExW(request_path.c_str(), consumed.c_str(),
              MOVEFILE_REPLACE_EXISTING);

  HelperLock lock;
  if (!lock.Acquire(directory, request.transaction_id)) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_HELPER_LOCKED");
    return 3;
  }

  WriteStatus(directory, request.transaction_id, L"starting");
  if (!WaitForProcessExit(request.main_pid, request.main_started, 60000) ||
      !WaitForProcessExit(request.tray_pid, request.tray_started, 60000)) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_HELPER_PROCESS_EXIT_TIMEOUT");
    return 4;
  }

  // 安装前独立二次验证（不信任主程序传入的任何"已验证"结论）。
  const auto inspection = nh::InspectPackage(request.package_path, nh::SignatureCheck::TrustedChain);
  if (!inspection.ok) {
    WriteStatus(directory, request.transaction_id, L"failed",
                inspection.failure_code);
    return 5;
  }
  if (inspection.identity.name != kExpectedIdentity ||
      inspection.identity.publisher != kExpectedPublisher ||
      inspection.identity.family_name != kExpectedFamily ||
      inspection.identity.architecture != L"x64") {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_PACKAGE_IDENTITY_MISMATCH");
    return 5;
  }
  if (inspection.identity.VersionString() != request.to_version) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_PACKAGE_VERSION_MISMATCH");
    return 5;
  }
  std::error_code size_error;
  const auto size =
      std::filesystem::file_size(request.package_path, size_error);
  if (size_error || size != request.package_size) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_DOWNLOAD_SIZE_MISMATCH");
    return 5;
  }
  std::vector<BYTE> digest;
  if (!nh::Sha256File(request.package_path, digest)) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_DOWNLOAD_HASH_MISMATCH");
    return 5;
  }
  std::wstring hex;
  for (BYTE byte : digest) {
    wchar_t piece[3]{};
    swprintf_s(piece, L"%02x", byte);
    hex += piece;
  }
  if (_wcsicmp(hex.c_str(), request.package_sha256.c_str()) != 0) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_DOWNLOAD_HASH_MISMATCH");
    return 5;
  }

  // 证据模式：验证、哈希、进程等待与锁都真实执行，但不部署、不激活、不回退。
  if (dry_run) {
    WriteStatus(directory, request.transaction_id, L"verified");
    return 0;
  }

  WriteStatus(directory, request.transaction_id, L"installing");
  int hresult = 0;
  std::wstring detail;
  if (!DeployPackage(request.package_path, hresult, detail)) {
    WriteStatus(directory, request.transaction_id, L"failed",
                L"UPDATE_INSTALL_DEPLOYMENT_FAILED", hresult);
    return 6;
  }

  DWORD new_process = 0;
  WriteStatus(directory, request.transaction_id, L"launchingNewVersion");
  if (!ActivateApp(new_process)) {
    std::wstring rollback_code = L"UPDATE_HEALTH_PROCESS_NOT_STARTED";
    int rollback_hresult = 0;
    const bool rolled_back =
        RollBack(request, rollback_code, rollback_hresult);
    WriteStatus(directory, request.transaction_id,
                rolled_back ? L"rolledBack" : L"failed", rollback_code,
                rollback_hresult);
    return 8;
  }

  WriteStatus(directory, request.transaction_id, L"waitingForHealth");
  if (WaitForHealth(request)) {
    WriteStatus(directory, request.transaction_id, L"succeeded");
    return 0;
  }

  std::wstring rollback_code;
  int rollback_hresult = 0;
  const bool rolled_back = RollBack(request, rollback_code, rollback_hresult);
  WriteStatus(directory, request.transaction_id,
              rolled_back ? L"rolledBack" : L"failed", rollback_code,
              rollback_hresult);
  return rolled_back ? 7 : 9;
}

int RunSelfTest() {
  int failures = 0;
  auto check = [&failures](bool condition, const char* name) {
    if (!condition) {
      std::printf("FAIL %s\n", name);
      ++failures;
    }
  };
  check(nh::IsPathUnderRoot(
            L"C:\\Updates\\1.9.1.0\\package.msix.ready", L"C:\\Updates"),
        "path under root");
  check(!nh::IsPathUnderRoot(
            L"C:\\Updates\\..\\evil.msix.ready", L"C:\\Updates"),
        "path traversal rejected");
  check(!nh::IsPathUnderRoot(L"C:\\Other\\package.msix.ready",
                                        L"C:\\Updates"),
        "other directory rejected");
  check(IsHex(L"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
              64),
        "sha256 hex accepted");
  check(!IsHex(L"token", 64), "short token rejected");
  FILETIME time{};
  check(ParseIso8601(L"2026-10-18T00:00:00Z", time),
        "iso8601 parsed");
  // 写入检查：在自身目录写一个临时文件（发布机与 CI 上这个目录一定可写）。
  const std::wstring probe_path =
      (std::filesystem::current_path() / L"update_helper_selftest.tmp").wstring();
  const bool temp_ok = WriteAllBytes(probe_path, "ok");
  DeleteFileW(probe_path.c_str());
  check(temp_ok, "temp write");
  if (failures == 0) std::printf("selftest ok\n");
  return failures == 0 ? 0 : 1;
}

}  // namespace

// 从已安装包内启动时，先把自身复制到包外再运行。
//
// 直接以 WindowsApps 里的镜像部署，会让助手自己占住包文件，Windows 返回
// ERROR_PACKAGES_IN_USE (0x80073D02)。父进程只负责复制并拉起子进程，随后退出，
// 子进程从 %TEMP% 运行，不再持有包内文件。
bool RelocateOutOfPackageIfNeeded(int argc, wchar_t** argv) {
  wchar_t module[MAX_PATH * 4]{};
  if (GetModuleFileNameW(nullptr, module, MAX_PATH * 4) == 0) return false;
  const std::wstring image(module);
  if (image.find(L"\\WindowsApps\\") == std::wstring::npos) return false;

  wchar_t temp[MAX_PATH * 2]{};
  if (GetTempPathW(MAX_PATH * 2, temp) == 0) return false;
  const std::wstring directory =
      std::wstring(temp) + L"BestPlanningUpdateHelper\\self-" +
      std::to_wstring(GetCurrentProcessId());
  std::error_code ec;
  std::filesystem::create_directories(directory, ec);
  if (ec) return false;
  const std::wstring target = directory + L"\\update_helper.exe";
  {
    std::ifstream source(image, std::ios::binary);
    std::ofstream destination(target, std::ios::binary | std::ios::trunc);
    if (!source || !destination) return false;
    destination << source.rdbuf();
    if (!destination.good()) return false;
  }

  std::wstring command = L"\"" + target + L"\"";
  for (int index = 1; index < argc; ++index) {
    command += L" \"";
    command += argv[index];
    command += L"\"";
  }
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  const BOOL started = CreateProcessW(
      target.c_str(), command.data(), nullptr, nullptr, FALSE,
      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process);
  if (!started) return false;
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return true;
}

int wmain(int argc, wchar_t** argv) {
  if (RelocateOutOfPackageIfNeeded(argc, argv)) return 0;
  SetConsoleOutputCP(CP_UTF8);
  winrt::init_apartment(winrt::apartment_type::single_threaded);
  if (argc < 2) {
    std::printf(
        "usage: update_helper --probe | --verify <msix> | --apply <request> "
        "[--dry-run] | --selftest\n");
    return 64;
  }
  const std::wstring command = argv[1];
  if (command == L"--probe") return RunProbe();
  if (command == L"--verify") {
    if (argc < 3) return 64;
    return RunVerify(argv[2]);
  }
  if (command == L"--apply") {
    if (argc < 3) return 64;
    const bool dry_run = argc > 3 && std::wstring(argv[3]) == L"--dry-run";
    return RunApply(argv[2], dry_run);
  }
  if (command == L"--selftest") return RunSelfTest();
  if (command == L"--version") {
    std::printf("%s\n", Utf8(kHelperVersion).c_str());
    return 0;
  }
  std::printf("unknown command\n");
  return 64;
}








