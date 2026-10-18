#include "elevation_broker.h"

#include <bcrypt.h>
#include <shellapi.h>
#include <sddl.h>

#include <winrt/Windows.Data.Json.h>

#include <cstdio>
#include <iterator>
#include <string>

#include "certificate_manager.h"
#include "elevation_channel.h"
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

// 协议版本从 1 提升到 2：父子进程来自同一 Setup EXE，因此不提供跨版本兼容模式。
constexpr int kProtocolVersion = 2;
constexpr wchar_t kCommandTrust[] = L"verify-and-trust-certificate";
constexpr DWORD kHandshakeTimeoutMs = 30000;
constexpr DWORD kResultTimeoutMs = 120000;
constexpr DWORD kHelperConnectTimeoutMs = 20000;

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

bool BooleanField(const JsonObject& object, const wchar_t* name, bool& valid) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::Boolean) {
      valid = false;
      return false;
    }
    return value.GetBoolean();
  } catch (...) {
    valid = false;
    return false;
  }
}

// 客户端连接：overlapped + 只要求"识别"级别模拟，绝不让普通权限服务端拿到
// 可用于模拟的管理员令牌（规格 §2.3）。
HANDLE ConnectToPipe(const std::wstring& pipe_name, DWORD timeout_ms) {
  const ULONGLONG deadline = GetTickCount64() + timeout_ms;
  for (;;) {
    HANDLE pipe = CreateFileW(pipe_name.c_str(), GENERIC_READ | GENERIC_WRITE, 0,
                              nullptr, OPEN_EXISTING,
                              FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT |
                                  SECURITY_IDENTIFICATION,
                              nullptr);
    if (pipe != INVALID_HANDLE_VALUE) {
      // 消息读模式是客户端句柄自己的属性；失败只影响分帧，不影响身份判断。
      DWORD mode = PIPE_READMODE_MESSAGE;
      SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr);
      return pipe;
    }
    if (GetLastError() != ERROR_PIPE_BUSY) return INVALID_HANDLE_VALUE;
    if (GetTickCount64() > deadline) return INVALID_HANDLE_VALUE;
    WaitNamedPipeW(pipe_name.c_str(), 1000);
  }
}

}  // namespace

ElevationFailureDecision DecideElevationFailure(
    const ElevationChannelResult& result, int timeout_ms) {
  ElevationFailureDecision decision;
  decision.detail = ElevationChannelDetail(
      result, timeout_ms > 0 ? static_cast<DWORD>(timeout_ms) : 0);
  switch (result.status) {
    case ElevationChannelStatus::Connected:
      // 不应被调用；保持保守，不终止进程。
      decision.error = ErrorCode::None;
      decision.terminate_helper = false;
      break;
    case ElevationChannelStatus::ChildExited:
      // 进程已经退出：报告真实退出码，不得再 TerminateProcess。
      decision.error = ErrorCode::ElevationFailed;
      decision.terminate_helper = false;
      break;
    case ElevationChannelStatus::TimedOut:
    case ElevationChannelStatus::ClientPidMismatch:
    case ElevationChannelStatus::ClientPidUnavailable:
    case ElevationChannelStatus::ConnectStartFailed:
    case ElevationChannelStatus::WaitFailed:
    case ElevationChannelStatus::EventCreationFailed:
    case ElevationChannelStatus::IoFailed:
    case ElevationChannelStatus::MessageTooLarge:
      // 握手尚未 ACK（证书绝不可能已写）：允许回收仍存活的辅助进程。
      decision.error = ErrorCode::ElevationFailed;
      decision.terminate_helper = true;
      break;
  }
  return decision;
}

ErrorCode MapElevatedResultCode(const std::wstring& stable_code) {
  if (stable_code.empty()) return ErrorCode::ElevationFailed;
  auto equals = [&stable_code](const wchar_t* candidate) {
    return _wcsicmp(stable_code.c_str(), candidate) == 0;
  };
  if (equals(L"INSTALLER_ELEVATION_RESOURCE_MISMATCH")) {
    return ErrorCode::ElevationResourceMismatch;
  }
  if (equals(L"INSTALLER_ELEVATION_DECLINED")) {
    return ErrorCode::ElevationDeclined;
  }
  if (equals(L"INSTALLER_CERTIFICATE_STORE_UNAVAILABLE")) {
    return ErrorCode::CertificateStoreUnavailable;
  }
  if (equals(L"INSTALLER_CERTIFICATE_IMPORT_FAILED")) {
    return ErrorCode::CertificateImportFailed;
  }
  return ErrorCode::ElevationFailed;
}

bool ValidateElevationHandshakeRequest(const std::string& payload,
                                       const TrustRequest& expected,
                                       const std::wstring& nonce_hex,
                                       std::wstring& rejected_field) {
  rejected_field.clear();
  JsonObject object{nullptr};
  if (!ParseJson(payload, object)) {
    rejected_field = L"malformed";
    return false;
  }
  bool valid = true;
  const double protocol = NumberField(object, L"protocolVersion", valid);
  const std::wstring nonce = StringField(object, L"nonce", valid);
  const std::wstring command = StringField(object, L"command", valid);
  const std::wstring metadata = StringField(object, L"metadataSha256", valid);
  const std::wstring package = StringField(object, L"packageSha256", valid);
  const std::wstring thumbprint =
      StringField(object, L"certificateThumbprint", valid);
  if (!valid) {
    rejected_field = L"malformed";
    return false;
  }
  if (static_cast<int>(protocol) != kProtocolVersion) {
    rejected_field = L"protocolVersion";
    return false;
  }
  if (_wcsicmp(nonce.c_str(), nonce_hex.c_str()) != 0) {
    rejected_field = L"nonce";
    return false;
  }
  if (_wcsicmp(command.c_str(), kCommandTrust) != 0) {
    rejected_field = L"command";
    return false;
  }
  if (_wcsicmp(metadata.c_str(), expected.metadata_sha256.c_str()) != 0) {
    rejected_field = L"metadataSha256";
    return false;
  }
  if (_wcsicmp(package.c_str(), expected.package_sha256.c_str()) != 0) {
    rejected_field = L"packageSha256";
    return false;
  }
  if (_wcsicmp(thumbprint.c_str(),
               expected.certificate_thumbprint.c_str()) != 0) {
    rejected_field = L"certificateThumbprint";
    return false;
  }
  return true;
}

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
  pipe_name_ = std::wstring(kElevationPipePrefix) + nonce_hex_;

  std::wstring sid;
  if (!CurrentUserSid(sid)) {
    error = L"current-user-sid";
    return false;
  }
  // 保留原始用户、SYSTEM、管理员三类主体；不扩大 ACL（规格 §2.3、§8.5）。
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

  // 三个标志缺一不可：双工、首实例（防抢占）、overlapped（等待/取消的契约）。
  pipe_ = CreateNamedPipeW(
      pipe_name_.c_str(),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1, kElevationMessageLimit, kElevationMessageLimit, 0, &security_);
  if (pipe_ == INVALID_HANDLE_VALUE) {
    error = L"create-pipe win32=" + std::to_wstring(GetLastError());
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

  // 命令行不再携带父 PID：身份来自返回的进程句柄与管道实际客户端 PID。
  const std::wstring parameters = L"--elevated-session --pipe \"" + pipe_name_ +
                                  L"\" --nonce " + nonce_hex_;
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
      outcome.detail = L"runas win32=" + std::to_wstring(status);
      outcome.win32_error = status;
    }
    return outcome;
  }

  // 没有进程句柄或 PID 时不等待管道、不读消息、不写证书：直接给出真实原因。
  const DWORD launched_pid =
      execute.hProcess != nullptr ? GetProcessId(execute.hProcess) : 0;
  if (execute.hProcess == nullptr || launched_pid == 0) {
    const DWORD status = GetLastError();
    if (execute.hProcess != nullptr) CloseHandle(execute.hProcess);
    CloseChannel();
    outcome.error = ErrorCode::ElevationFailed;
    outcome.win32_error = status;
    outcome.detail =
        L"elevated-process-id-unavailable win32=" + std::to_wstring(status);
    return outcome;
  }
  outcome.launched_pid = launched_pid;

  const DWORD wait_ms = timeout_ms > 0 ? static_cast<DWORD>(timeout_ms) : 0;
  const ElevationChannelResult channel = WaitForExpectedElevationClient(
      pipe_, execute.hProcess, launched_pid, wait_ms);
  outcome.channel_status = ElevationChannelToken(channel.status);
  outcome.win32_error = channel.win32_error;
  outcome.child_exit_code = channel.child_exit_code;
  if (!channel.ok()) {
    // 每条失败路径恰好一次 TerminateProcess（且只在 pre-ACK）与一次 CloseHandle。
    const ElevationFailureDecision decision =
        DecideElevationFailure(channel, timeout_ms);
    if (decision.terminate_helper) {
      TerminateProcess(execute.hProcess, 3);
    }
    WaitForSingleObject(execute.hProcess, 1000);
    CloseHandle(execute.hProcess);
    CloseChannel();
    outcome.error = decision.error;
    outcome.detail = decision.detail;
    return outcome;
  }
  outcome.client_pid = channel.actual_client_pid;
  outcome.child_exit_code = STILL_ACTIVE;

  // 1) 核对协议版本、nonce、固定命令与三项资源指纹；任何一项不符都不回复 accepted。
  std::string incoming;
  const ElevationChannelResult request_read =
      ReadElevationMessage(pipe_, incoming, kHandshakeTimeoutMs);
  if (!request_read.ok()) {
    // 连请求都没读到：这是安全通信失败，不是"资源不一致"，也不能谎报成超时。
    // 此刻仍未 ACK，可以安全回收仍存活的辅助进程。
    outcome.error = ErrorCode::ElevationFailed;
    outcome.channel_status = ElevationChannelToken(request_read.status);
    outcome.win32_error = request_read.win32_error;
    outcome.detail = L"handshake-read-failed " +
                     ElevationChannelDetail(request_read, kHandshakeTimeoutMs);
    TerminateProcess(execute.hProcess, 3);
    WaitForSingleObject(execute.hProcess, 1000);
    CloseHandle(execute.hProcess);
    CloseChannel();
    return outcome;
  }

  std::wstring rejected_field;
  const bool accepted = ValidateElevationHandshakeRequest(
      incoming, request, nonce_hex_, rejected_field);

  JsonObject ack;
  ack.SetNamedValue(L"ok", JsonValue::CreateBooleanValue(accepted));
  if (accepted) {
    ack.SetNamedValue(L"command", JsonValue::CreateStringValue(L"accepted"));
  }
  WriteElevationMessage(pipe_, nh::Utf8FromWide(ack.Stringify().c_str()),
                        kHandshakeTimeoutMs);
  if (!accepted) {
    outcome.error = ErrorCode::ElevationResourceMismatch;
    outcome.detail = L"handshake-rejected field=" + rejected_field;
    // 已明确拒绝（未 ACK accepted）：证书不可能被写。辅助进程读到 ok=false 会自行
    // 以 5 退出，因此这里只等它退出，不替它决定生死。
    WaitForSingleObject(execute.hProcess, 10000);
    CloseHandle(execute.hProcess);
    CloseChannel();
    return outcome;
  }

  // 2) 已 ACK：从这里开始证书可能已被写入，因此不得再终止辅助进程。
  std::string result_payload;
  const ElevationChannelResult result_read =
      ReadElevationMessage(pipe_, result_payload, kResultTimeoutMs);
  if (!result_read.ok()) {
    outcome.error = ErrorCode::ElevationFailed;
    outcome.channel_status = ElevationChannelToken(result_read.status);
    outcome.win32_error = result_read.win32_error;
    outcome.detail =
        L"elevated-result-unavailable " +
        ElevationChannelDetail(result_read, kResultTimeoutMs);
    WaitForSingleObject(execute.hProcess, 10000);
    CloseHandle(execute.hProcess);
    CloseChannel();
    return outcome;
  }

  JsonObject object{nullptr};
  if (!ParseJson(result_payload, object)) {
    outcome.error = ErrorCode::ElevationResourceMismatch;
    outcome.detail = L"elevated-result-malformed";
  } else {
    bool valid = true;
    const bool ok = BooleanField(object, L"ok", valid);
    const bool already = BooleanField(object, L"alreadyPresent", valid);
    const std::wstring thumbprint = StringField(object, L"thumbprint", valid);
    const std::wstring metadata =
        StringField(object, L"metadataSha256", valid);
    const std::wstring package = StringField(object, L"packageSha256", valid);
    const std::wstring error_code = StringField(object, L"errorCode", valid);
    if (!valid ||
        _wcsicmp(metadata.c_str(), request.metadata_sha256.c_str()) != 0 ||
        _wcsicmp(package.c_str(), request.package_sha256.c_str()) != 0) {
      outcome.error = ErrorCode::ElevationResourceMismatch;
      outcome.detail = L"elevated-resource-mismatch";
    } else if (!ok) {
      outcome.error = MapElevatedResultCode(error_code);
      outcome.detail =
          error_code.empty() ? L"elevated-failure" : error_code;
    } else if (_wcsicmp(thumbprint.c_str(),
                        request.certificate_thumbprint.c_str()) != 0) {
      outcome.error = ErrorCode::ElevationResourceMismatch;
      outcome.detail = L"thumbprint-mismatch";
    } else {
      outcome.ok = true;
      outcome.already_present = already;
      outcome.thumbprint = thumbprint;
      outcome.error = ErrorCode::None;
    }
  }

  CloseChannel();
  DWORD exit_code = STILL_ACTIVE;
  WaitForSingleObject(execute.hProcess, 10000);
  if (GetExitCodeProcess(execute.hProcess, &exit_code)) {
    outcome.child_exit_code = exit_code;
  }
  CloseHandle(execute.hProcess);
  return outcome;
}

int RunElevatedSession(const std::vector<std::wstring>& arguments) {
  const ElevatedSessionArguments parsed =
      ParseElevatedSessionArguments(arguments);
  if (!parsed.valid) return 2;

  HANDLE pipe = ConnectToPipe(parsed.pipe_name, kHelperConnectTimeoutMs);
  if (pipe == INVALID_HANDLE_VALUE) return 4;

  // 从**自己的**只读资源重读载荷并计算摘要；不采信命令行或主进程提供的路径。
  EmbeddedPayload payload;
  ErrorCode error = ErrorCode::Internal;
  std::wstring detail;
  if (!ReadEmbeddedPayload(payload, error, detail)) {
    CloseHandle(pipe);
    return 6;
  }
  CertificateInfo certificate;
  if (!VerifyCertificateMetadata(payload.metadata, payload.certificate,
                                 certificate, error, detail)) {
    CloseHandle(pipe);
    return 6;
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
    WriteElevationMessage(pipe, nh::Utf8FromWide(object.Stringify().c_str()),
                          kHandshakeTimeoutMs);
  };

  // 1) 请求：协议版本、nonce、固定命令与载荷摘要。
  JsonObject request;
  request.SetNamedValue(L"protocolVersion",
                        JsonValue::CreateNumberValue(kProtocolVersion));
  request.SetNamedValue(L"nonce", JsonValue::CreateStringValue(parsed.nonce_hex));
  request.SetNamedValue(L"command",
                        JsonValue::CreateStringValue(kCommandTrust));
  request.SetNamedValue(L"metadataSha256",
                        JsonValue::CreateStringValue(metadata_sha));
  request.SetNamedValue(L"packageSha256",
                        JsonValue::CreateStringValue(package_sha));
  request.SetNamedValue(L"certificateThumbprint",
                        JsonValue::CreateStringValue(thumbprint));
  if (!WriteElevationMessage(pipe, nh::Utf8FromWide(request.Stringify().c_str()),
                             kHandshakeTimeoutMs)
           .ok()) {
    CloseHandle(pipe);
    return 4;
  }

  // 2) 主进程确认后才允许写入证书存储；摘要不一致时这里必须停下。
  std::string incoming;
  bool accepted = false;
  const ElevationChannelResult ack =
      ReadElevationMessage(pipe, incoming, kHandshakeTimeoutMs);
  if (ack.ok()) {
    JsonObject object{nullptr};
    bool valid = true;
    if (ParseJson(incoming, object)) {
      accepted = BooleanField(object, L"ok", valid) && valid;
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
