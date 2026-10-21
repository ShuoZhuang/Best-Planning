// 证书策略（规格 §8.6、§10.2）。
//
// 只管理安装器内嵌的那一张公开证书：写入 `LocalMachine\TrustedPeople`，
// 绝不写 Root，绝不导入私钥，相同主题但指纹不同不视为同一张证书。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace planner::installer {

struct CertificateInfo {
  std::vector<BYTE> der;
  std::wstring subject;
  std::wstring thumbprint;  // SHA-1，40 位大写十六进制（与证书管理器一致）
  std::wstring sha256;      // DER 的 SHA-256，64 位小写十六进制
  std::wstring public_key_sha256;
  FILETIME not_after{};
  bool expired = false;
};

bool ParseCertificate(const std::vector<BYTE>& der, CertificateInfo& info,
                      std::wstring& error);

// 证书是否已在 `LocalMachine\TrustedPeople`（按指纹匹配）。
bool IsTrustedForSideloading(const std::vector<BYTE>& der, bool& present,
                             std::wstring& error);

struct TrustResult {
  bool ok = false;
  bool already_present = false;
  std::wstring thumbprint;
  std::wstring error;
};

// 需要管理员：把固定证书写入 `LocalMachine\TrustedPeople`（幂等）。
TrustResult TrustCertificate(const std::vector<BYTE>& der);

// 只有同时满足下列条件才允许删除本次新增的证书（规格 §10.2）：
//   - 安装前不存在；
//   - 没有任何同身份的包仍登记在系统里；
//   - 证书主题正是固定的发布者。
bool CanSafelyRemoveCertificate(const std::vector<BYTE>& der,
                                bool was_present_before,
                                std::wstring& reason);

bool RemoveCertificate(const std::vector<BYTE>& der, std::wstring& error);

}  // namespace planner::installer
