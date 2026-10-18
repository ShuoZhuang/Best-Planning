#include "elevation_broker.h"

#include <bcrypt.h>
#include <shellapi.h>
#include <sddl.h>
#include <tlhelp32.h>

#include <winrt/Windows.Data.Json.h>

#include <cstdio>
#include <iterator>
#include <string>

#include "certificate_manager.h"
#include "native_shared/text.h"
#include "package_verifier.h"
#include "payload_reader.h"
#include "secure_session.h"

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "shell32.lib")

using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;
using winrt::Windows::Data::Json::JsonValueType;

namespace planner::installer {
namespace {

namespace nh = planner::native;

constexpr int kProtocolVersion = 1;
constexpr wchar_t kCommandTrust[] = L"verify-and-trust-certificate";
constexpr wchar_t kPipePrefix[] = L"\\\\.\\pipe\\BestPlanningSetup-";
constexpr DWORD kMessageLimit = 64 * 1024;

std::vector<BYTE> RandomBytes(size_t count) {
  std::vector<BYTE> bytes(count);
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    bytes.clear();
  }
  return bytes;
}

bool CurrentUserSid(std::wstring& sid) {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  DWORD size = 0;
  GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  std::vector<BYTE> buffer(size);
  bool ok = false;
  if (GetTokenInformation(token, TokenUser, buffer.data(), size, &size)) {
    const TOKEN_USER* user = reinterpret_cast<const TOKEN_USER*>(buffer.data());
    wchar_t* text = nullptr;
    if (ConvertSidToStringSidW(user->User.Sid, &text)) {
      sid = text;
      LocalFree(text);
      ok = true;
    }
  }
  CloseHandle(token);
  return ok;
}

bool WriteMessage(HANDLE pipe, const std::string& payload) {
  DWORD written = 0;
  return WriteFile(pipe, payload.data(), static_cast<DWORD>(payload.size()),
                   &written, nullptr) != FALSE &&
         written == payload.size();
}

bool ReadMessage(HANDLE pipe, std::string& payload, DWORD timeout_ms) {
  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (overlapped.hEvent == nullptr) return false;
  std::vector<char> buffer(kMessageLimit);
  DWORD read = 0;
  BOOL ok = ReadFile(pipe, buffer.data(), kMessageLimit, &read, &overlapped);
  if (!ok && GetLastError() == ERROR_IO_PENDING) {
    if (WaitForSingleObject(overlapped.hEvent, timeout_ms) != WAIT_OBJECT_0) {
      CancelIoEx(pipe, &overlapped);
      CloseHandle(overlapped.hEvent);
      return false;
    }
    ok = GetOverlappedResult(pipe, &overlapped, &read, FALSE);
  }
  CloseHandle(overlapped.hEvent);
  if (!ok) return false;
  payload.assign(buffer.data(), read);
  return true;
}

bool ParseJson(const std::string& utf8, JsonObject& object) {
  try {
    object = JsonObject::Parse(nh::WideFromUtf8(utf8));
    return true;
  } catch (...) {
    return false;
  }
}

std::wstring StringField(const JsonObject& object, const wchar_t* name,
                         bool& valid) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::String) {
      valid = false;
      return {};
    }
    return value.GetString().c_str();
  } catch (...) {
    valid = false;
    return {};
  }
}

double NumberField(const JsonObject& object, const wchar_t* name, bool& valid) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::Number) {
      valid = false;
      return 0;
    }
    return value.GetNumber();
  } catch (...) {
    valid = false;
    return 0;
  }
}

bool ParentIsSameExecutable(DWORD expected_parent) {
  DWORD parent = 0;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  if (Process32FirstW(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == GetCurrentProcessId()) {
        parent = entry.th32ParentProcessID;
        break;
      }
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  if (parent == 0 || parent != expected_parent) return false;

  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, parent);
  if (process == nullptr) return false;
  wchar_t parent_path[MAX_PATH * 2]{};
  DWORD parent_size = static_cast<DWORD>(std::size(parent_path));
  const bool parent_ok =
      QueryFullProcessImageNameW(process, 0, parent_path, &parent_size) != FALSE;
  CloseHandle(process);
  if (!parent_ok) return false;

  wchar_t self_path[MAX_PATH * 2]{};
  DWORD self_size = static_cast<DWORD>(std::size(self_path));
  if (!QueryFullProcessImageNameW(GetCurrentProcess(), 0, self_path, &self_size)) {
    return false;
  }
  return _wcsicmp(parent_path, self_path) == 0;
}

HANDLE ConnectToPipe(const std::wstring& pipe_name, DWORD timeout_ms) {
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  for (;;) {
    HANDLE pipe = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                              nullptr, OPEN_EXISTING, 0, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) return pipe;
    if (GetLastError() != ERROR_PIPE_BUSY) return INVALID_HANDLE_VALUE;
    if (GetTickCount64() > deadline) return INVALID_HANDLE_VALUE;
    WaitNamedPipeW(pipe_name.c_str(), 1000);
  }
}

ErrorCode MapChildCode(const std::wstring& code) {
  if (_wcsicmp(code.c_str(), L"INSTALLER_ELEVATION_RESOURCE_MISMATCH") == 0) {
    return ErrorCode::ElevationResourceMismatch;
  }
  if (_wcsicmp(code.c_str(), L"INSTALLER_CERTIFICATE_IMPORT_FAILED") == 0 ||
      _wcsicmp(code.c_str(), L"INSTALLER_CERTIFICATE_STORE_UNAVAILABLE") == 0) {
    return ErrorCode::CertificateImportFailed;
  }
  if (_wcsicmp(code.c_str(), L"INSTALLER_PAYLOAD_MISSING") == 0 ||
      _wcsicmp(code.c_str(), L"INSTALLER_PACKAGE_SIGNATURE_INVALID") == 0 ||
      _wcsicmp(code.c_str(), L"INSTALLER_PACKAGE_IDENTITY_MISMATCH") == 0) {
    return ErrorCode::ElevationFailed;
  }
  return ErrorCode::ElevationFailed;
}

}  // namespace

bool IsProcessElevated() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
  TOKEN_ELEVATION elevation{};
  DWORD size = sizeof(elevation);
  const bool ok = GetTokenInformation(token, TokenElevation, &elevation, size,
                                      &size) != FALSE &&
                  elevation.TokenIsElevated != 0;
  CloseHandle(token);
  return ok;
}

ElevationBroker::ElevationBroker(std::wstring executable_path)
    : executable_path_(std::move(executable_path)) {}

ElevationBroker::~ElevationBroker() { CloseChannel(); }

bool ElevationBroker::CreateChannel(std::wstring& error) {
  const std::vector<BYTE> nonce = RandomBytes(32);
  if (nonce.size() != 32) {
    error = L"random";
    return false;
  }
  nonce_hex_ = nh::HexEncode(nonce);
  pipe_name_ = kPipePrefix + nonce_hex_;

  std::wstring sid;
  if (!CurrentUserSid(sid)) {
    error = L"current-user-sid";
    return false;
  }
  const std::wstring sddl =
      L"D:(A;;GA;;;" + sid + L")(A;;GA;;;SY)(A;;GA;;;BA)";
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &descriptor_, nullptr)) {
    error = L"security-descriptor";
    return false;
  }
  security_.nLength = sizeof(security_);
  security_.lpSecurityDescriptor = descriptor_;
  security_.bInheritHandle = FALSE;

  pipe_ = CreateNamedPipeW(
      pipe_name_.c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT, 1, kMessageLimit,
      kMessageLimit, 0, &security_);
  if (pipe_ == INVALID_HANDLE_VALUE) {
    error = L"create-pipe";
    LocalFree(descriptor_);
    descriptor_ = nullptr;
    return false;
  }
  return true;
}

void ElevationBroker::CloseChannel() {
  if (pipe_ != INVALID_HANDLE_VALUE) {
    DisconnectNamedPipe(pipe_);
    CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
  }
  if (descriptor_ != nullptr) {
    LocalFree(descriptor_);
    descriptor_ = nullptr;
  }
}

TrustOutcome ElevationBroker::RequestCertificateTrust(
    const TrustRequest& request, int timeout_ms) {
  TrustOutcome outcome;
  std::wstring error;
  if (!CreateChannel(error)) {
    outcome.error = ErrorCode::ElevationFailed;
    outcome.detail = L"channel " + error;
    return outcome;
  }

  const std::wstring parameters =
      L"--elevated-session --pipe \"" + pipe_name_ + L"\" --nonce " +
      nonce_hex_ + L" --parent " + std::to_wstring(GetCurrentProcessId());
  SHELLEXECUTEINFOW execute{};
  execute.cbSize = sizeof(execute);
  execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
  execute.lpVerb = L"runas";
  execute.lpFile = executable_path_.c_str();
  execute.lpParameters = parameters.c_str();
  execute.nShow = SW_HIDE;
  if (!ShellExecuteExW(&execute)) {
    const DWORD status = GetLastError();
    CloseChannel();
    if (status == ERROR_CANCELLED) {
      outcome.declined = true;
      outcome.error = ErrorCode::ElevationDeclined;
      outcome.detail = L"uac-declined";
    } else {
      outcome.error = ErrorCode::ElevationFailed;
      outcome.detail = L"runas " + std::to_wstring(status);
    }
    return outcome;
  }

  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  bool connected = false;
  if (overlapped.hEvent != nullptr) {
    const BOOL result = ConnectNamedPipe(pipe_, &overlapped);
    DWORD status = result ? ERROR_SUCCESS : GetLastError();
    if (status == ERROR_PIPE_CONNECTED) {
      connected = true;
    } else if (status == ERROR_IO_PENDING) {
      if (WaitForSingleObject(overlapped.hEvent, static_cast<DWORD>(timeout_ms)) ==
          WAIT_OBJECT_0) {
        DWORD transferred = 0;
        connected = GetOverlappedResult(pipe_, &overlapped, &transferred, FALSE) != FALSE;
      } else {
        CancelIoEx(pipe_, &overlapped);
      }
    }
    CloseHandle(overlapped.hEvent);
  }
  if (!connected) {
    outcome.error = ErrorCode::ElevationFailed;
    outcome.detail = L"pipe-connect-timeout";
    if (execute.hProcess != nullptr) {
      TerminateProcess(execute.hProcess, 3);
      CloseHandle(execute.hProcess);
    }
    CloseChannel();
    return outcome;
  }

  // 1) 读取提权进程的请求并核对 nonce / 协议 / 载荷摘要。
  std::string incoming;
  bool accepted = false;
  if (ReadMessage(pipe_, incoming, 30000)) {
    JsonObject object{nullptr};
    bool valid = true;
    if (ParseJson(incoming, object)) {
      const double protocol = NumberField(object, L"protocolVersion", valid);
      const std::wstring nonce = StringField(object, L"nonce", valid);
      const std::wstring command = StringField(object, L"command", valid);
      const std::wstring metadata = StringField(object, L"metadataSha256", valid);
      const std::wstring package = StringField(object, L"packageSha256", valid);
      const std::wstring thumbprint =
          StringField(object, L"certificateThumbprint", valid);
      accepted = valid && static_cast<int>(protocol) == kProtocolVersion &&
                 _wcsicmp(nonce.c_str(), nonce_hex_.c_str()) == 0 &&
                 _wcsicmp(command.c_str(), kCommandTrust) == 0 &&
                 _wcsicmp(metadata.c_str(), request.metadata_sha256.c_str()) == 0 &&
                 _wcsicmp(package.c_str(), request.package_sha256.c_str()) == 0 &&
                 _wcsicmp(thumbprint.c_str(),
                          request.certificate_thumbprint.c_str()) == 0;
    }
  }
  JsonObject ack;
  ack.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(accepted));
  if (accepted) {
    ack.SetNamedValue(L"command", JsonValue::CreateStringValue(L"accepted"));
  }
  WriteMessage(pipe_, nh::Utf8FromWide(ack.Stringify().c_str()));
  if (!accepted) {
    outcome.error = ErrorCode::ElevationFailed;
    outcome.detail = L"handshake-rejected";
    if (execute.hProcess != nullptr) {
      WaitForSingleObject(execute.hProcess, 10000);
      CloseHandle(execute.hProcess);
    }
    CloseChannel();
    return outcome;
  }

  // 2) 读取提权进程的处理结果。
  bool replied = false;
  if (ReadMessage(pipe_, incoming, 120000)) {
    JsonObject object{nullptr};
    bool valid = true;
    if (ParseJson(incoming, object)) {
      const bool ok = [&]() {
        try {
          return object.GetNamedBoolean(L"ok", false);
        } catch (...) {
          return false;
        }
      }();
      const bool already = [&]() {
        try {
          return object.GetNamedBoolean(L"alreadyPresent", false);
        } catch (...) {
          return false;
        }
      }();
      const std::wstring thumbprint = StringField(object, L"thumbprint", valid);
      const std::wstring metadata = StringField(object, L"metadataSha256", valid);
      const std::wstring package = StringField(object, L"packageSha256", valid);
      const std::wstring error_code = StringField(object, L"errorCode", valid);
      if (!valid || _wcsicmp(metadata.c_str(), request.metadata_sha256.c_str()) != 0 ||
          _wcsicmp(package.c_str(), request.package_sha256.c_str()) != 0) {
        outcome.error = ErrorCode::ElevationResourceMismatch;
        outcome.detail = L"elevated-resource-mismatch";
      } else if (!ok) {
        outcome.error = MapChildCode(error_code);
        outcome.detail = error_code;
      } else if (_wcsicmp(thumbprint.c_str(),
                          request.certificate_thumbprint.c_str()) != 0) {
        outcome.error = ErrorCode::ElevationResourceMismatch;
        outcome.detail = L"thumbprint-mismatch";
      } else {
        outcome.ok = true;
        outcome.already_present = already;
        outcome.thumbprint = thumbprint;
        outcome.error = ErrorCode::None;
        replied = true;
      }
    }
  }
  if (!replied && outcome.ok) outcome.ok = false;
  if (!replied && outcome.error == ErrorCode::Internal) {
    outcome.error = ErrorCode::ElevationFailed;
    outcome.detail = L"no-result";
  }

  CloseChannel();
  if (execute.hProcess != nullptr) {
    WaitForSingleObject(execute.hProcess, 10000);
    CloseHandle(execute.hProcess);
  }
  return outcome;
}

int RunElevatedSession(const std::vector<std::wstring>& arguments) {
  std::wstring pipe_name;
  std::wstring nonce_hex;
  DWORD parent = 0;
  for (size_t index = 0; index < arguments.size(); ++index) {
    if (_wcsicmp(arguments[index].c_str(), L"--pipe") == 0 &&
        index + 1 < arguments.size()) {
      pipe_name = arguments[++index];
    } else if (_wcsicmp(arguments[index].c_str(), L"--nonce") == 0 &&
               index + 1 < arguments.size()) {
      nonce_hex = arguments[++index];
    } else if (_wcsicmp(arguments[index].c_str(), L"--parent") == 0 &&
               index + 1 < arguments.size()) {
      parent = static_cast<DWORD>(_wtoi(arguments[++index].c_str()));
    }
  }
  if (pipe_name.empty() || !nh::IsHex(nonce_hex, 64) || parent == 0) return 2;
  if (!ParentIsSameExecutable(parent)) return 3;

  HANDLE pipe = ConnectToPipe(pipe_name, 20000);
  if (pipe == INVALID_HANDLE_VALUE) return 4;

  // 从**自己的**只读资源重读载荷并计算摘要；不采信命令行或主进程提供的路径。
  EmbeddedPayload payload;
  ErrorCode error = ErrorCode::Internal;
  std::wstring detail;
  if (!ReadEmbeddedPayload(payload, error, detail)) {
    CloseHandle(pipe);
    return 5;
  }
  CertificateInfo certificate;
  if (!VerifyCertificateMetadata(payload.metadata, payload.certificate,
                                 certificate, error, detail)) {
    CloseHandle(pipe);
    return 5;
  }
  const std::wstring metadata_sha = payload.metadata.RawSha256();
  const std::wstring package_sha = payload.metadata.package_sha256;
  const std::wstring thumbprint = certificate.thumbprint;

  auto send_result = [&pipe](bool ok, const std::wstring& code,
                             const std::wstring& result_thumbprint,
                             const std::wstring& result_metadata,
                             const std::wstring& result_package,
                             bool already_present) {
    JsonObject object;
    object.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(ok));
    object.SetNamedValue(L"alreadyPresent",
                         JsonValue::CreateBooleanValue(already_present));
    object.SetNamedValue(L"thumbprint",
                         JsonValue::CreateStringValue(result_thumbprint));
    object.SetNamedValue(L"errorCode", JsonValue::CreateStringValue(code));
    object.SetNamedValue(L"metadataSha256",
                         JsonValue::CreateStringValue(result_metadata));
    object.SetNamedValue(L"packageSha256",
                         JsonValue::CreateStringValue(result_package));
    WriteMessage(pipe, nh::Utf8FromWide(object.Stringify().c_str()));
  };

  // 1) 请求：nonce、协议版本、命令与载荷摘要。
  JsonObject request;
  request.SetNamedValue(L"protocolVersion",
                        JsonValue::CreateNumberValue(kProtocolVersion));
  request.SetNamedValue(L"nonce", JsonValue::CreateStringValue(nonce_hex));
  request.SetNamedValue(L"command",
                        JsonValue::CreateStringValue(kCommandTrust));
  request.SetNamedValue(L"metadataSha256",
                        JsonValue::CreateStringValue(metadata_sha));
  request.SetNamedValue(L"packageSha256",
                        JsonValue::CreateStringValue(package_sha));
  request.SetNamedValue(L"certificateThumbprint",
                        JsonValue::CreateStringValue(thumbprint));
  if (!WriteMessage(pipe, nh::Utf8FromWide(request.Stringify().c_str()))) {
    CloseHandle(pipe);
    return 4;
  }

  // 2) 主进程确认后才允许写入证书存储；摘要不一致时这里必须停下。
  std::string incoming;
  bool accepted = false;
  if (ReadMessage(pipe, incoming, 30000)) {
    JsonObject object{nullptr};
    if (ParseJson(incoming, object)) {
      try {
        accepted = object.GetNamedBoolean(L"ok", false);
      } catch (...) {
        accepted = false;
      }
    }
  }
  if (!accepted) {
    CloseHandle(pipe);
    return 5;
  }

  // 3) 在受限临时会话里复核成品文件（大小、哈希、身份、签名、签名者）。
  SecureSession session;
  std::wstring session_error;
  if (!session.Create(session_error) ||
      !session.WriteFile(L"payload.msix", payload.package.data(),
                         payload.package.size(), session_error)) {
    send_result(false, L"INSTALLER_PAYLOAD_MISSING", thumbprint, metadata_sha,
                package_sha, false);
    CloseHandle(pipe);
    return 6;
  }
  const auto outcome =
      VerifyPayloadFile(payload.metadata, payload.certificate,
                        session.FilePath(L"payload.msix"), false);
  std::wstring cleanup_error;
  session.Cleanup(cleanup_error);
  if (!outcome.ok) {
    send_result(false, DescribeError(outcome.error).code, thumbprint,
                metadata_sha, package_sha, false);
    CloseHandle(pipe);
    return 6;
  }

  // 4) 只写固定证书到 LocalMachine\TrustedPeople，写完即退。
  const TrustResult trust = TrustCertificate(payload.certificate);
  if (trust.ok) {
    send_result(true, {}, trust.thumbprint, metadata_sha, package_sha,
                trust.already_present);
    CloseHandle(pipe);
    return 0;
  }
  send_result(false, trust.error.empty() ? L"INSTALLER_CERTIFICATE_IMPORT_FAILED"
                                         : trust.error,
              trust.thumbprint, metadata_sha, package_sha, false);
  CloseHandle(pipe);
  return 7;
}
}  // namespace planner::installer
