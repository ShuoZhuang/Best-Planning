// MSIX 包的独立检查：包身份、结构与签名（规格 §8.2、§16.1）。
//
// **为什么不用调用方的验证结果**：主程序可能被替换、请求文件也可能被改；安装器与更新
// 助手都必须在部署前**自己**从成品里读一遍身份与签名。这里不信任任何传入的"已验证"标记。
//
// 三档检查刻意分开（规格 §8.2）：
//   None          只读身份（预检、诊断）
//   Cryptographic 签名在密码学上有效，且发布者相符——首次安装时证书尚未受信任
//   TrustedChain  再加 Windows 证书链信任（导入证书之后才可能通过）
#pragma once

#include <windows.h>
#include <wincrypt.h>

#include <cstdint>
#include <string>
#include <vector>

#include "native_shared/planner_identity.h"

namespace planner::native {

struct PackageIdentity {
  std::wstring name;
  std::wstring publisher;
  std::wstring family_name;
  std::wstring architecture;
  std::uint64_t version = 0;
  bool packaged = false;

  std::wstring VersionString() const;
  PackageVersion Version() const { return PackageVersion::FromEncoded(version); }
};

enum class SignatureCheck { None, Cryptographic, TrustedChain };

struct PackageSignature {
  bool present = false;
  bool crypto_valid = false;
  bool chain_trusted = false;
  bool publisher_matches = false;
  std::wstring failure_code;
  std::wstring detail;
  std::vector<BYTE> signer_certificate;  // DER 编码
  std::wstring signer_subject;
};

struct InspectionResult {
  bool ok = false;
  std::wstring failure_code;
  std::wstring detail;
  PackageIdentity identity;
  PackageSignature signature;
};

// 读取包身份并按 check 强度校验签名。expected_publisher 为空时不检查发布者。
InspectionResult InspectPackage(const std::wstring& path, SignatureCheck check,
                                const std::wstring& expected_publisher = kPublisher);

// 只做签名相关检查：PKCS#7 完整性、签名者、链信任状态与发布者。
PackageSignature VerifyPackageSignature(const std::wstring& path,
                                        const std::wstring& expected_publisher);

// 签名者证书与固定证书是否为同一张（逐字节比较 DER）。
bool SameCertificate(const std::vector<BYTE>& left, const std::vector<BYTE>& right);

// 从证书 DER 读取 Subject（`CN=..., O=..., C=...`），失败返回空。
std::wstring CertificateSubject(const std::vector<BYTE>& certificate);

// 当前进程所属的包身份（更新助手随 MSIX 一起安装时能读到）。
bool CurrentPackageIdentity(PackageIdentity& out);

}  // namespace planner::native
