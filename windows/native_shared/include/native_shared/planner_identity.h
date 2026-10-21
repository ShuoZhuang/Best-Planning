// 冻结的包身份与版本比较（规格 §8.3）。
//
// 包族名**不**在这里硬编码：它由 Publisher 派生（Windows 的 PublisherId 算法），
// 并与成品清单里读到的值互相核对，避免"展示名/路径/族名"三处漂移。
#pragma once

#include <cstdint>
#include <string>

namespace planner::native {

inline constexpr wchar_t kIdentityName[] = L"ShuoZhuang.PersonalPlanner";
inline constexpr wchar_t kPublisher[] = L"CN=Shuo Zhuang, O=Personal User, C=CN";
inline constexpr wchar_t kArchitecture[] = L"x64";

struct PackageVersion {
  unsigned major = 0;
  unsigned minor = 0;
  unsigned build = 0;
  unsigned revision = 0;

  static bool Parse(const std::wstring& value, PackageVersion& out);
  static PackageVersion FromEncoded(std::uint64_t encoded);

  std::uint64_t Encode() const;
  std::wstring ToString() const;
  bool operator==(const PackageVersion& other) const;
  bool operator!=(const PackageVersion& other) const { return !(*this == other); }
  bool IsHigherThan(const PackageVersion& other) const;
};

// Windows PublisherId：Publisher 的 UTF-16LE 字节 SHA-256 前 8 字节，
// 按 Crockford base32 编成 13 个字符。与 Dart 侧 `publisherIdFor` 同一算法。
std::wstring PublisherId(const std::wstring& publisher);
std::wstring PackageFamilyName(const std::wstring& identity_name,
                               const std::wstring& publisher);

// Publisher 比较：忽略大小写与逗号后的空格差异，逐段比较 RDN。
bool SamePublisher(const std::wstring& left, const std::wstring& right);
bool SameArchitecture(const std::wstring& left, const std::wstring& right);

}  // namespace planner::native
