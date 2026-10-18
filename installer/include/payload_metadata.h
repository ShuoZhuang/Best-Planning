// 内嵌载荷元数据（规格 §7.2）。
//
// 全部字段由发布构建从成品**自动生成**，禁止人工在多处复制。安装器只信任
// 内嵌资源里的这一份，并与实际 MSIX 和固定证书逐项核对。
#pragma once

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

#include "native_shared/planner_identity.h"

namespace planner::installer {

struct PayloadMetadata {
  int schema_version = 1;
  std::wstring installer_version;
  std::wstring app_version;
  std::wstring msix_version;
  std::wstring identity_name;
  std::wstring publisher;
  std::wstring family_name;
  std::wstring architecture;
  std::uint64_t package_size = 0;
  std::wstring package_sha256;
  std::wstring certificate_sha256;
  std::wstring certificate_thumbprint;
  unsigned minimum_windows_build = 0;
  std::wstring asset_file_name;
  std::string raw_json;

  planner::native::PackageVersion MsixVersionValue() const;
  std::wstring RawSha256() const;

  // 与固定身份和格式规则比对；失败时 failure 为稳定错误编号。
  bool Validate(std::wstring& failure) const;

  static bool Parse(const std::vector<BYTE>& utf8_json, PayloadMetadata& out,
                    std::wstring& failure);

  std::wstring ToJson() const;
};

}  // namespace planner::installer
