// MSIX 包的独立检查：包身份、结构与签名（规格 §10.1 第三层 / §10.2）。
//
// **为什么不用 Dart 侧的验证结果**：主程序可能被替换、请求文件也可能被改；助手必须在
// 安装前**自己**从成品里读一遍身份与签名。这里不信任任何传入的"已验证"标记。
#pragma once

#include <windows.h>
#include <appxpackaging.h>
#include <wincrypt.h>

#include <cstdint>
#include <string>
#include <vector>

namespace update_helper {

struct PackageIdentity {
  std::wstring name;
  std::wstring publisher;
  std::wstring family_name;
  std::wstring architecture;
  std::uint64_t version = 0;
  bool packaged = false;

  std::wstring VersionString() const;
};

struct InspectionResult {
  bool ok = false;
  std::wstring failure_code;
  std::wstring detail;
  PackageIdentity identity;
};

// 从成品里读取包身份；verify_signature 为 true 时同时验证签名与证书链。
InspectionResult InspectPackage(const std::wstring& path, bool verify_signature);

// 当前进程所属的包身份（助手随 MSIX 一起安装，因此这里能读到包族名与版本）。
bool CurrentPackageIdentity(PackageIdentity& out);

// SHA-256（用于请求里的大小/哈希二次核对）。
bool Sha256File(const std::wstring& path, std::vector<BYTE>& digest);

// 规范路径判断：path 是否在 root 之下（按目录边界，不接受 `..` 越界）。
bool IsPathUnderRoot(const std::wstring& path, const std::wstring& root);

}  // namespace update_helper
