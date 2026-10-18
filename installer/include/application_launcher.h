// 启动已安装的应用（规格 §7.3）。
//
// AUMID 只从**实际登记结果**解析，不依赖展示名称、磁盘路径或硬编码。
#pragma once

#include <windows.h>

#include <string>

namespace planner::installer {

struct LaunchResult {
  bool ok = false;
  std::wstring aumid;
  DWORD process_id = 0;
  std::wstring detail;
};

LaunchResult LaunchInstalledApplication(const std::wstring& package_full_name);

}  // namespace planner::installer
