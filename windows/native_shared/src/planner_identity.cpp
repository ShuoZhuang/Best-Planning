#include "native_shared/planner_identity.h"

#include <windows.h>

#include <bcrypt.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

#include "native_shared/text.h"

#pragma comment(lib, "bcrypt.lib")

namespace planner::native {
namespace {

std::wstring ToUpper(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towupper(c)); });
  return value;
}

std::wstring Trim(const std::wstring& value) {
  const auto first = value.find_first_not_of(L" \t\r\n");
  if (first == std::wstring::npos) return {};
  const auto last = value.find_last_not_of(L" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::map<std::wstring, std::wstring> ParseDistinguishedName(
    const std::wstring& value) {
  std::map<std::wstring, std::wstring> attributes;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t comma = value.find(L',', start);
    const std::wstring part = Trim(value.substr(
        start, comma == std::wstring::npos ? std::wstring::npos
                                           : comma - start));
    if (!part.empty()) {
      const size_t equals = part.find(L'=');
      if (equals != std::wstring::npos) {
        attributes[ToUpper(Trim(part.substr(0, equals)))] = Trim(
            part.substr(equals + 1));
      }
    }
    if (comma == std::wstring::npos) break;
    start = comma + 1;
  }
  return attributes;
}

}  // namespace

bool PackageVersion::Parse(const std::wstring& value, PackageVersion& out) {
  unsigned major = 0, minor = 0, build = 0, revision = 0;
  if (swscanf_s(value.c_str(), L"%u.%u.%u.%u", &major, &minor, &build,
                &revision) != 4) {
    return false;
  }
  out.major = major;
  out.minor = minor;
  out.build = build;
  out.revision = revision;
  return true;
}

PackageVersion PackageVersion::FromEncoded(std::uint64_t encoded) {
  PackageVersion version;
  version.major = static_cast<unsigned>((encoded >> 48) & 0xFFFF);
  version.minor = static_cast<unsigned>((encoded >> 32) & 0xFFFF);
  version.build = static_cast<unsigned>((encoded >> 16) & 0xFFFF);
  version.revision = static_cast<unsigned>(encoded & 0xFFFF);
  return version;
}

std::uint64_t PackageVersion::Encode() const {
  return (static_cast<std::uint64_t>(major) << 48) |
         (static_cast<std::uint64_t>(minor) << 32) |
         (static_cast<std::uint64_t>(build) << 16) |
         static_cast<std::uint64_t>(revision);
}

std::wstring PackageVersion::ToString() const {
  wchar_t buffer[32]{};
  swprintf_s(buffer, L"%u.%u.%u.%u", major, minor, build, revision);
  return buffer;
}

bool PackageVersion::operator==(const PackageVersion& other) const {
  return major == other.major && minor == other.minor && build == other.build &&
         revision == other.revision;
}

bool PackageVersion::IsHigherThan(const PackageVersion& other) const {
  return Encode() > other.Encode();
}

std::wstring PublisherId(const std::wstring& publisher) {
  static const wchar_t* kAlphabet = L"0123456789abcdefghjkmnpqrstvwxyz";
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  BYTE digest[32]{};
  bool ok = false;
  do {
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    0) < 0) {
      break;
    }
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
      break;
    }
    // std::wstring 在 Windows 上是 UTF-16 码元，直接取字节即 UTF-16LE。
    const BYTE* bytes = reinterpret_cast<const BYTE*>(publisher.data());
    const ULONG byte_count =
        static_cast<ULONG>(publisher.size() * sizeof(wchar_t));
    if (BCryptHashData(hash, const_cast<BYTE*>(bytes), byte_count, 0) < 0) {
      break;
    }
    if (BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0) break;
    ok = true;
  } while (false);
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return {};

  std::uint64_t value = 0;
  for (int i = 0; i < 8; ++i) {
    value = (value << 8) | digest[i];
  }
  std::wstring result;
  result.reserve(13);
  for (int index = 0; index < 13; ++index) {
    const int consumed = (index + 1) * 5;
    const std::uint64_t chunk =
        consumed <= 64 ? (value >> (64 - consumed)) & 0x1F
                       : (value << (consumed - 64)) & 0x1F;
    result.push_back(kAlphabet[chunk]);
  }
  return result;
}

std::wstring PackageFamilyName(const std::wstring& identity_name,
                               const std::wstring& publisher) {
  const std::wstring id = PublisherId(publisher);
  if (id.empty()) return {};
  return identity_name + L"_" + id;
}

bool SamePublisher(const std::wstring& left, const std::wstring& right) {
  const auto expected = ParseDistinguishedName(left);
  const auto actual = ParseDistinguishedName(right);
  if (expected.empty() || actual.empty()) return false;
  if (expected.size() != actual.size()) return false;
  for (const auto& [key, value] : expected) {
    const auto found = actual.find(key);
    if (found == actual.end()) return false;
    if (_wcsicmp(found->second.c_str(), value.c_str()) != 0) return false;
  }
  return true;
}

bool SameArchitecture(const std::wstring& left, const std::wstring& right) {
  return _wcsicmp(left.c_str(), right.c_str()) == 0;
}

}  // namespace planner::native
