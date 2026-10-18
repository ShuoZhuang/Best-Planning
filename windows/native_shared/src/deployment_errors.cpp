#include "native_shared/deployment_errors.h"

namespace planner::native {
namespace {

constexpr HRESULT PackageInUse = static_cast<HRESULT>(0x80073D02L);
constexpr HRESULT PackageAlreadyExists = static_cast<HRESULT>(0x80073CFBL);
constexpr HRESULT PackageUpdatePolicy = static_cast<HRESULT>(0x80073CF3L);
constexpr HRESULT InstallPackageDowngrade = static_cast<HRESULT>(0x80073D06L);
constexpr HRESULT InstallPackageInvalid = static_cast<HRESULT>(0x80070650L);
constexpr HRESULT InstallPackageRejected = static_cast<HRESULT>(0x80070659L);
constexpr HRESULT DeletePending = static_cast<HRESULT>(0x800700B7L);
constexpr HRESULT CertificateUntrustedRoot = static_cast<HRESULT>(0x800B0109L);
constexpr HRESULT CertificateChaining = static_cast<HRESULT>(0x800B010AL);
constexpr HRESULT ExplicitDistrust = static_cast<HRESULT>(0x800B0111L);
constexpr HRESULT PackageNotSupportedOnFileSystem =
    static_cast<HRESULT>(0x80073D13L);

struct Entry {
  HRESULT error;
  DeploymentFailure failure;
};

const Entry kEntries[] = {
    {PackageInUse,
     {L"INSTALLER_DEPLOY_PACKAGE_IN_USE",
      L"优计主义仍在运行，Windows 无法替换正在使用的文件。",
      L"请保存工作并退出应用（包括托盘图标）后重试。", 21}},
    {PackageAlreadyExists,
     {L"INSTALLER_DEPLOY_ALREADY_INSTALLED",
      L"Windows 报告该版本已经安装。", L"可以点“启动优计主义”直接使用，或选择重新安装。",
      40}},
    {PackageUpdatePolicy,
     {L"INSTALLER_DEPLOY_POLICY_REJECTED",
      L"系统安装策略拒绝了这次部署。", L"请确认没有通过组策略强制限制应用安装，然后重试。",
      41}},
    {InstallPackageDowngrade,
     {L"INSTALLER_DEPLOY_DOWNGRADE_REJECTED",
      L"安装包版本低于当前已安装版本，Windows 拒绝降级。",
      L"请下载并运行最新版本，或在“设置 → 应用”中卸载后重新安装。", 60}},
    {InstallPackageInvalid,
     {L"INSTALLER_DEPLOY_PACKAGE_INVALID",
      L"Windows 无法解析这个安装包。", L"请重新下载官方安装器；如果仍然失败，请打开日志反馈。",
      41}},
    {InstallPackageRejected,
     {L"INSTALLER_DEPLOY_REJECTED",
      L"系统策略拒绝了这次安装。", L"请检查“设置 → 应用 → 应用和功能”的旁加载设置后重试。",
      41}},
    {DeletePending,
     {L"INSTALLER_DEPLOY_PENDING_RESTART",
      L"Windows 需要重启后才能完成上一次卸载或更新。",
      L"请重启电脑后再运行安装器。", 42}},
    {CertificateUntrustedRoot,
     {L"INSTALLER_DEPLOY_CERTIFICATE_UNTRUSTED",
      L"安装包的签名证书尚未被这台电脑信任。",
      L"请重新运行安装器，让它再次请求一次管理员授权来信任证书。", 31}},
    {CertificateChaining,
     {L"INSTALLER_DEPLOY_CERTIFICATE_CHAIN",
      L"安装包的证书链不完整。", L"请重新下载官方安装器；如果仍然失败，请打开日志反馈。",
      31}},
    {ExplicitDistrust,
     {L"INSTALLER_DEPLOY_CERTIFICATE_DISTRUSTED",
      L"这台电脑显式不信任安装包的证书。",
      L"请不要在普通界面强行绕过；如确需安装，请先由管理员检查证书策略。", 31}},
    {PackageNotSupportedOnFileSystem,
     {L"INSTALLER_DEPLOY_FILESYSTEM_UNSUPPORTED",
      L"当前磁盘的文件系统不支持安装该应用。", L"请把应用安装到系统盘后重试。", 41}},
    {E_ACCESSDENIED,
     {L"INSTALLER_DEPLOY_ACCESS_DENIED",
      L"当前账户没有完成这次安装所需的权限。",
      L"请使用有管理员授权的账户，或在 UAC 提示中输入管理员凭据。", 41}},
};

}  // namespace

DeploymentFailure DescribeDeploymentFailure(HRESULT error) {
  for (const auto& entry : kEntries) {
    if (entry.error == error) return entry.failure;
  }
  return {L"INSTALLER_DEPLOY_FAILED",
          L"Windows 未能完成这次安装。", L"请重启电脑后重试；仍然失败时请打开日志并反馈。",
          41};
}

}  // namespace planner::native
