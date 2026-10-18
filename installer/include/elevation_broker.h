// 一次 UAC 的双进程权限隔离（规格 §7.1、§8.5）。
//
// 只允许一组有限命令：验证并信任内嵌固定证书。协议字段、nonce 与载荷摘要都必须
// 完全匹配；提权进程不接受任意路径、脚本、注册表位置或证书存储区。
//
// 连接者的身份来自两件**可核对**的事实：`ShellExecuteExW` 返回的进程句柄
// （启动者的 PID）与命名管道实际客户端 PID（内核给出）。进程树的父 PID 不再参与
// 判断，也不再有任何"父进程 PID"命令行参数。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

#include "elevation_channel.h"
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

  // 可审计信息（只写日志，不参与判定）：PID、退出码、稳定状态 token、Win32 错误码。
  DWORD launched_pid = 0;
  DWORD client_pid = 0;
  DWORD child_exit_code = STILL_ACTIVE;
  std::wstring channel_status;
  DWORD win32_error = ERROR_SUCCESS;
};

// 连接阶段失败 → 用户级错误、稳定 detail 与"是否允许终止仍存活的 helper"。
//
// 纯函数，不发起 UAC、不写系统，因此可以逐条固定 §2.4 的语义：
// 只有真正等待超时才允许出现 `pipe-connect-timeout`；子进程提前退出带真实退出码；
// PID 不符必须在 ACK 之前拒绝。`terminate_helper` 只在握手尚未 ACK 时为 true。
struct ElevationFailureDecision {
  ErrorCode error = ErrorCode::ElevationFailed;
  std::wstring detail;
  bool terminate_helper = false;
};

ElevationFailureDecision DecideElevationFailure(
    const ElevationChannelResult& result, int timeout_ms);

// 辅助进程返回的稳定错误码 → 主进程错误码。真实证书写入失败与存储不可用各自保留
// 专有含义，不能被折叠成同一条。
ErrorCode MapElevatedResultCode(const std::wstring& stable_code);

// 校验提权进程的握手请求（纯函数，不写系统）：只有协议版本 2、同一个 nonce、
// 固定命令、三项资源指纹全部一致才返回 true。`rejected_field` 给出第一个不一致的
// 字段名用于日志——只写字段名，不写 nonce 值。
bool ValidateElevationHandshakeRequest(const std::string& payload,
                                       const TrustRequest& expected,
                                       const std::wstring& nonce_hex,
                                       std::wstring& rejected_field);

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
