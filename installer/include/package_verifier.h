// 载荷校验（规格 §8.1、§8.2）。
//
// 顺序固定：长度 → SHA-256 → 包清单身份/发布者/架构/版本 → 签名密码学完整性
// → 实际签名者等于内嵌固定证书 → （可选）Windows 证书链信任。
// 任何一步失败都不得进入证书导入或部署。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

#include "certificate_manager.h"
#include "installer_errors.h"
#include "native_shared/package_inspector.h"
#include "payload_metadata.h"

namespace planner::installer {

struct VerificationOutcome {
  bool ok = false;
  ErrorCode error = ErrorCode::Internal;
  std::wstring detail;
  planner::native::PackageIdentity identity;
  planner::native::PackageSignature signature;
  std::uint64_t package_size = 0;
  std::wstring package_sha256;
};

// 校验内嵌证书与元数据声明一致（DER 摘要、指纹、有效期）。
bool VerifyCertificateMetadata(const PayloadMetadata& metadata,
                               const std::vector<BYTE>& certificate,
                               CertificateInfo& info, ErrorCode& error,
                               std::wstring& detail);

// 校验已释放到磁盘的 MSIX；require_trust 为 true 时要求证书链已受信任。
VerificationOutcome VerifyPayloadFile(const PayloadMetadata& metadata,
                                      const std::vector<BYTE>& certificate,
                                      const std::wstring& package_path,
                                      bool require_trust);

}  // namespace planner::installer
