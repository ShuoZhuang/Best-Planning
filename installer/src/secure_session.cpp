#include "secure_session.h"

#include <aclapi.h>
#include <bcrypt.h>
#include <sddl.h>

#include <cstdio>
#include <string>
#include <vector>

#include "native_shared/text.h"

#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "bcrypt.lib")

namespace planner::installer {
namespace {

namespace nh = planner::native;

constexpr wchar_t kSessionPrefix[] = L"BestPlanningSetup-";
constexpr wchar_t kRestrictedSddl[] =
    L"D:P(A;OICI;FA;;;OW)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)";

bool ApplyRestrictedAcl(const std::wstring& directory, std::wstring& error) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          kRestrictedSddl, SDDL_REVISION_1, &descriptor, nullptr)) {
    error = L"security-descriptor";
    return false;
  }
  BOOL present = FALSE;
  BOOL defaulted = FALSE;
  PACL dacl = nullptr;
  bool ok = false;
  // 注意：`GetSecurityDescriptorDacl` 的第 4 个参数必须传真实地址；本环境传入
  // NULL 会直接访问冲突（2026-10-18 实测），不要省这个局部变量。
  if (GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) &&
      present && dacl != nullptr) {
    const DWORD status = SetNamedSecurityInfoW(
        const_cast<LPWSTR>(directory.c_str()), SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION, nullptr,
        nullptr, dacl, nullptr);
    ok = status == ERROR_SUCCESS;
    if (!ok) error = L"acl-apply";
  } else {
    error = L"acl-missing";
  }
  LocalFree(descriptor);
  return ok;
}
bool RandomBytes(size_t count, std::vector<BYTE>& out) {
  out.resize(count);
  return BCryptGenRandom(nullptr, out.data(), static_cast<ULONG>(out.size()),
                         BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0;
}

}  // namespace

SecureSession::~SecureSession() {
  if (!directory_.empty()) {
    std::wstring error;
    Cleanup(error);
  }
}

std::wstring SecureSession::FilePath(const wchar_t* name) const {
  if (directory_.empty()) return {};
  return directory_ + L"\\" + name;
}

bool SecureSession::Create(std::wstring& error) {
  wchar_t temp[MAX_PATH + 1]{};
  const DWORD length = GetTempPathW(MAX_PATH, temp);
  if (length == 0) {
    error = L"temp-path";
    return false;
  }
  const std::wstring base(temp);
  if (nh::HasReparsePoint(base)) {
    error = L"temp-reparse";
    return false;
  }
  for (int attempt = 0; attempt < 8; ++attempt) {
    std::vector<BYTE> random;
    if (!RandomBytes(16, random)) {
      error = L"random";
      return false;
    }
    const std::wstring candidate = base + kSessionPrefix + nh::HexEncode(random);
    if (CreateDirectoryW(candidate.c_str(), nullptr)) {
      directory_ = candidate;
      break;
    }
    if (GetLastError() != ERROR_ALREADY_EXISTS) {
      error = L"create-directory " + std::to_wstring(GetLastError()) + L" " + candidate;
      return false;
    }
  }
  if (directory_.empty()) {
    error = L"session-name-collision";
    return false;
  }
  if (nh::HasReparsePoint(directory_)) {
    error = L"session-reparse";
    Cleanup(error);
    return false;
  }
  if (!ApplyRestrictedAcl(directory_, error)) {
    Cleanup(error);
    return false;
  }
  return true;
}

bool SecureSession::WriteFile(const wchar_t* name, const void* data, size_t size,
                              std::wstring& error) {
  const std::wstring path = FilePath(name);
  if (path.empty()) {
    error = L"session-missing";
    return false;
  }
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    // 既有路径不覆盖（规格 §8.4）。
    error = L"create-file";
    return false;
  }
  bool ok = true;
  const BYTE* bytes = static_cast<const BYTE*>(data);
  size_t offset = 0;
  while (offset < size) {
    const DWORD chunk = static_cast<DWORD>(
        (size - offset) > (1u << 20) ? (1u << 20) : (size - offset));
    DWORD written = 0;
    if (!::WriteFile(file, bytes + offset, chunk, &written, nullptr) ||
        written == 0) {
      ok = false;
      break;
    }
    offset += written;
  }
  if (ok) FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(path.c_str());
    error = L"write-file";
    return false;
  }
  if (nh::HasReparsePoint(path)) {
    DeleteFileW(path.c_str());
    error = L"reparse-point";
    return false;
  }
  return true;
}

bool SecureSession::ReadFile(const wchar_t* name, std::vector<BYTE>& out,
                             std::wstring& error) const {
  const std::wstring path = FilePath(name);
  if (path.empty()) {
    error = L"session-missing";
    return false;
  }
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    error = L"open-file";
    return false;
  }
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart > (1LL << 31)) {
    CloseHandle(file);
    error = L"file-size";
    return false;
  }
  out.resize(static_cast<size_t>(size.QuadPart));
  size_t offset = 0;
  while (offset < out.size()) {
    const DWORD chunk = static_cast<DWORD>(
        (out.size() - offset) > (1u << 20) ? (1u << 20)
                                           : (out.size() - offset));
    DWORD read = 0;
    if (!::ReadFile(file, out.data() + offset, chunk, &read, nullptr) ||
        read == 0) {
      CloseHandle(file);
      out.clear();
      error = L"read-file";
      return false;
    }
    offset += read;
  }
  CloseHandle(file);
  return true;
}

std::vector<BYTE> SecureSession::IssueToken() {
  // 只签发一次；重复调用返回空，且**不清掉**已签发的那一份。
  if (token_issued_) return {};
  std::vector<BYTE> token;
  if (!RandomBytes(32, token)) return {};
  token_ = token;
  token_issued_ = true;
  token_consumed_ = false;
  return token_;
}

bool SecureSession::ConsumeToken(const std::vector<BYTE>& token) {
  if (!token_issued_ || token_consumed_) return false;
  if (token.size() != token_.size() || token.empty()) return false;
  for (size_t index = 0; index < token.size(); ++index) {
    if (token[index] != token_[index]) return false;
  }
  token_consumed_ = true;
  return true;
}

bool SecureSession::Cleanup(std::wstring& error) {
  if (directory_.empty()) return true;
  bool ok = true;
  WIN32_FIND_DATAW data{};
  HANDLE find = FindFirstFileW((directory_ + L"\\*").c_str(), &data);
  if (find != INVALID_HANDLE_VALUE) {
    do {
      const std::wstring name = data.cFileName;
      if (name == L"." || name == L"..") continue;
      const std::wstring path = directory_ + L"\\" + name;
      if ((data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
        RemoveDirectoryW(path.c_str());
        continue;
      }
      if (!DeleteFileW(path.c_str())) ok = false;
    } while (FindNextFileW(find, &data));
    FindClose(find);
  }
  if (!RemoveDirectoryW(directory_.c_str())) {
    ok = false;
    error = L"remove-session-directory";
    return false;
  }
  directory_.clear();
  token_.clear();
  return ok;
}

}  // namespace planner::installer
