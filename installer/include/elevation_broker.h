// 一次 UAC 的双进程权限隔离（规格 §7.1、§8.5）。
//
// 只允许一组有限命令：验证并信任内嵌固定证书。协议字段、nonce 与载荷摘要都必须
// 完全匹配；提权进程不接受任意路径、脚本、注册表位置或证书存储区。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

#include "installer_errors.h"
#include "payload_metadata.h"

namespace planner::installer {

struct TrustRequest {
  std::wstring metadata_sha256;
  std::wstring package_sha256;
  std::wstring certificate_thumbprint;
};

struct TrustOutcome {
  bool ok = false;
  bool declined = false;      // 用户在 UAC 中拒绝授权
  bool already_present = false;
  std::wstring thumbprint;
  ErrorCode error = ErrorCode::Internal;
  std::wstring detail;
};

class ElevationBroker {
 public:
  explicit ElevationBroker(std::wstring executable_path);
  ~ElevationBroker();

  ElevationBroker(const ElevationBroker&) = delete;
  ElevationBroker& operator=(const ElevationBroker&) = delete;

  // 建立受保护管道、发起一次 UAC，并等待提权进程返回结构化结果。
  TrustOutcome RequestCertificateTrust(const TrustRequest& request,
                                       int timeout_ms = 180000);

 private:
  bool CreateChannel(std::wstring& error);
  void CloseChannel();

  std::wstring executable_path_;
  std::wstring pipe_name_;
  std::wstring nonce_hex_;
  HANDLE pipe_ = INVALID_HANDLE_VALUE;
  SECURITY_ATTRIBUTES security_{};
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
};

// 提权进程入口：只做"重读资源 → 重校验 → 写 TrustedPeople"。
int RunElevatedSession(const std::vector<std::wstring>& arguments);

bool IsProcessElevated();

}  // namespace planner::installer
