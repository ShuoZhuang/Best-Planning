#include "native_shared/text.h"

#include <bcrypt.h>

#include <algorithm>

#pragma comment(lib, "bcrypt.lib")

namespace planner::native {
namespace {

std::wstring StripTrailingSeparators(std::wstring value) {
  while (!value.empty() && (value.back() == L'\\' || value.back() == L'/')) {
    value.pop_back();
  }
  return value;
}

}  // namespace

std::string Utf8FromWide(const std::wstring& value) {
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

std::wstring WideFromUtf8(const std::string& value) {
  if (value.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                         0);
  std::wstring result(length > 0 ? length - 1 : 0, L'\0');
  if (length > 1) {
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), length);
  }
  return result;
}

std::wstring HexEncode(const std::vector<BYTE>& bytes) {
  static const wchar_t* kDigits = L"0123456789abcdef";
  std::wstring result;
  result.reserve(bytes.size() * 2);
  for (BYTE byte : bytes) {
    result.push_back(kDigits[(byte >> 4) & 0x0F]);
    result.push_back(kDigits[byte & 0x0F]);
  }
  return result;
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

bool HexEquals(const std::wstring& hex, const std::vector<BYTE>& bytes) {
  if (hex.size() != bytes.size() * 2) return false;
  return _wcsicmp(hex.c_str(), HexEncode(bytes).c_str()) == 0;
}

bool Sha256Bytes(const void* data, size_t size, std::vector<BYTE>& digest) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  bool ok = false;
  do {
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    0) < 0) {
      break;
    }
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
      break;
    }
    if (BCryptHashData(hash, static_cast<PUCHAR>(const_cast<void*>(data)),
                       static_cast<ULONG>(size), 0) < 0) {
      break;
    }
    digest.resize(32);
    if (BCryptFinishHash(hash, digest.data(),
                         static_cast<ULONG>(digest.size()), 0) < 0) {
      digest.clear();
      break;
    }
    ok = true;
  } while (false);
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  return ok;
}

bool Sha256File(const std::wstring& path, std::vector<BYTE>& digest) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  bool ok = false;
  do {
    if (file == INVALID_HANDLE_VALUE) break;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    0) < 0) {
      break;
    }
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
      break;
    }
    std::vector<BYTE> buffer(1 << 20);
    DWORD read = 0;
    bool read_failed = false;
    while (ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                    &read, nullptr) &&
           read > 0) {
      if (BCryptHashData(hash, buffer.data(), read, 0) < 0) {
        read_failed = true;
        break;
      }
    }
    if (read_failed) break;
    digest.resize(32);
    if (BCryptFinishHash(hash, digest.data(),
                         static_cast<ULONG>(digest.size()), 0) < 0) {
      break;
    }
    ok = true;
  } while (false);
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  return ok;
}

bool IsPathUnderRoot(const std::wstring& path, const std::wstring& root) {
  wchar_t full_path[MAX_PATH * 2]{};
  wchar_t full_root[MAX_PATH * 2]{};
  if (GetFullPathNameW(path.c_str(), MAX_PATH * 2, full_path, nullptr) == 0) {
    return false;
  }
  if (GetFullPathNameW(root.c_str(), MAX_PATH * 2, full_root, nullptr) == 0) {
    return false;
  }
  const std::wstring candidate(full_path);
  const std::wstring base = StripTrailingSeparators(full_root);
  if (base.empty()) return false;
  if (candidate.size() <= base.size() + 1) return false;
  if (_wcsnicmp(candidate.c_str(), base.c_str(), base.size()) != 0) {
    return false;
  }
  return candidate[base.size()] == L'\\' || candidate[base.size()] == L'/';
}

bool HasReparsePoint(const std::wstring& path) {
  wchar_t full_path[MAX_PATH * 2]{};
  if (GetFullPathNameW(path.c_str(), MAX_PATH * 2, full_path, nullptr) == 0) {
    return true;  // 解析不出来时按不安全处理
  }
  std::wstring current(full_path);
  for (;;) {
    const DWORD attributes = GetFileAttributesW(current.c_str());
    if (attributes != INVALID_FILE_ATTRIBUTES &&
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      return true;
    }
    const size_t separator = current.find_last_of(L"\\/");
    if (separator == std::wstring::npos || separator == 0) break;
    // 保留盘符根（`C:\`）或 UNC 前缀。
    if (separator == 2 && current[1] == L':') break;
    current = current.substr(0, separator);
    if (current.size() <= 3 && current[1] == L':') {
      const DWORD root = GetFileAttributesW(current.c_str());
      if (root != INVALID_FILE_ATTRIBUTES &&
          (root & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        return true;
      }
      break;
    }
  }
  return false;
}

}  // namespace planner::native
