// 包部署、登记查询与 AUMID 启动（规格 §7.3、§9.5、§9.6）。
//
// 更新助手与离线安装器共用同一份实现：部署错误转换、登记状态判定和 AUMID 解析
// 只要出现两份，就会在升级路径上缓慢漂移成"一边能装、一边不能装"。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace planner::native {

struct InstalledPackage {
  bool found = false;
  std::wstring name;
  std::wstring publisher;
  std::wstring family_name;
  std::wstring full_name;
  std::wstring version;  // 四段式文本
  std::wstring architecture;
  bool status_ok = false;
  bool needs_attention = false;  // 已登记但状态异常（需修复）
};

struct PackageDeploymentResult {
  bool ok = false;
  HRESULT error = S_OK;
  std::wstring error_text;
};

// 查询当前用户已登记的同身份包（不含其他用户）。
bool QueryInstalledPackage(const std::wstring& identity_name,
                           InstalledPackage& out, std::wstring& error);

// 列出当前用户已登记的同身份包（用于证书安全回收判定：是否存在依赖该证书的包）。
std::vector<InstalledPackage> FindPackagesForIdentity(const std::wstring& identity_name,
                                                      std::wstring& error);

// 以当前进程的用户身份部署（首次安装与原地升级都走这里）。
PackageDeploymentResult DeployPackage(const std::wstring& package_path);

// 同版本"重新安装"：覆盖已安装的同一版本，不先卸载（规格 §9.6）。
PackageDeploymentResult ReinstallSameVersion(const std::wstring& package_path);

// 重新登记已安装的同一版本（修复注册关系，不先卸载）。
PackageDeploymentResult RegisterInstalledPackage(const std::wstring& package_full_name);

// 从实际登记结果解析 AUMID；解析失败时不猜测、不拼接。
bool ResolveAumid(const std::wstring& package_full_name, std::wstring& aumid,
                  std::wstring& error);

// 是否有该包族的进程正在运行；返回第一个命中的 PID。
bool IsPackageRunning(const std::wstring& family_name, DWORD& process_id);

// 通过 ApplicationActivationManager 启动；不经过 shell，不执行任意命令行。
bool ActivateAumid(const std::wstring& aumid, DWORD& process_id,
                   std::wstring& error);

std::wstring HResultMessage(HRESULT error);

}  // namespace planner::native
