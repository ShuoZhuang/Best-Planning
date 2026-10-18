// 最小 ZIP 读取器（MSIX 是 ZIP），用于 AppxPackaging 不可用时的降级路径。
//
// 只做两件事：按名字找到条目、解出内容。签名仍由 `package_inspector.cpp` 的
// CryptoAPI 代码验证；这里不判断包是否可信。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace update_helper {

/// 读取 ZIP 中的一个条目。条目不存在、格式不支持或解压失败时返回 false。
bool ReadZipEntry(const std::wstring& path, const std::string& entry_name,
                  std::vector<BYTE>& out);

}  // namespace update_helper
