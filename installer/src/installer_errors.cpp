#include "installer_errors.h"

#include <iterator>

namespace planner::installer {
namespace {

constexpr ErrorDescription kDescriptions[] = {
    {L"INSTALLER_OK", L"安装完成", L"优计主义已经安装完成。", L"可以从开始菜单打开。",
     ExitCode::Success},
    {L"INSTALLER_CANCELLED", L"已取消安装", L"你取消了这次安装。",
     L"需要时重新运行安装器即可。", ExitCode::Cancelled},
    {L"INSTALLER_PAYLOAD_MISSING", L"安装器文件不完整",
     L"安装器内部缺少必需的安装载荷。",
     L"请重新下载官方安装器；不要只复制文件的一部分。", ExitCode::PayloadInvalid},
    {L"INSTALLER_PAYLOAD_SIZE_MISMATCH", L"安装包大小不符",
     L"内嵌安装包的长度与发布时记录的不一致。", L"请重新下载官方安装器。",
     ExitCode::PayloadInvalid},
    {L"INSTALLER_PAYLOAD_HASH_MISMATCH", L"安装包校验失败",
     L"内嵌安装包的内容与发布时记录的 SHA-256 不一致，可能已损坏或被替换。",
     L"请重新下载官方安装器。", ExitCode::PayloadInvalid},
    {L"INSTALLER_METADATA_INVALID", L"安装器信息不完整",
     L"安装器内的载荷信息无法解析。", L"请重新下载官方安装器。",
     ExitCode::PayloadInvalid},
    {L"INSTALLER_METADATA_VERSION_UNSUPPORTED", L"安装器版本过旧",
     L"这个安装器的数据格式已经不再受支持。", L"请下载最新版本的安装器。",
     ExitCode::Unsupported},
    {L"INSTALLER_PACKAGE_IDENTITY_MISMATCH", L"安装包身份不符",
     L"内嵌安装包的包身份与安装器固定的身份不一致。",
     L"请重新下载官方安装器。", ExitCode::PayloadInvalid},
    {L"INSTALLER_PACKAGE_PUBLISHER_MISMATCH", L"安装包发布者不符",
     L"内嵌安装包的发布者与安装器固定的发布者不一致。",
     L"请重新下载官方安装器。", ExitCode::PayloadInvalid},
    {L"INSTALLER_PACKAGE_ARCH_MISMATCH", L"安装包架构不符",
     L"内嵌安装包不是 x64 版本。", L"请下载 x64 版本的安装器。",
     ExitCode::PayloadInvalid},
    {L"INSTALLER_PACKAGE_VERSION_MISMATCH", L"安装包版本不符",
     L"内嵌安装包的版本与安装器记录的目标版本不一致。",
     L"请重新下载官方安装器。", ExitCode::PayloadInvalid},
    {L"INSTALLER_PACKAGE_SIGNATURE_INVALID", L"安装包签名无效",
     L"内嵌安装包的数字签名无法验证，内容可能已被修改。",
     L"请重新下载官方安装器。", ExitCode::PayloadInvalid},
    {L"INSTALLER_CERTIFICATE_UNTRUSTED", L"签名证书尚未受信任",
     L"安装包的签名证书还没有被这台电脑信任。",
     L"请重新运行安装器，并在 UAC 提示中同意一次管理员授权。",
     ExitCode::CertificateFailed},
    {L"INSTALLER_CERTIFICATE_IMPORT_FAILED", L"无法信任安装证书",
     L"安装器没能把签名证书写入本机的“受信任人”存储。",
     L"请确认已同意 UAC 授权后重试；仍然失败时请打开日志反馈。",
     ExitCode::CertificateFailed},
    {L"INSTALLER_CERTIFICATE_STORE_UNAVAILABLE", L"无法访问证书存储",
     L"系统证书存储区暂时不可用。", L"请重启电脑后重试。",
     ExitCode::CertificateFailed},
    {L"INSTALLER_ELEVATION_DECLINED", L"未获得管理员授权",
     L"安装需要一次管理员授权来信任签名证书，授权被取消。",
     L"请重新运行安装器，并在 UAC 提示中选择“是”。", ExitCode::Cancelled},
    {L"INSTALLER_ELEVATION_FAILED", L"管理员授权步骤未完成",
     L"安装器启动的管理员辅助进程未能建立安全连接。证书尚未写入，应用尚未安装。",
     L"请重试；如果仍然失败，请打开日志并反馈错误编号。",
     ExitCode::CertificateFailed},
    {L"INSTALLER_ELEVATION_RESOURCE_MISMATCH", L"安装器资源不一致",
     L"提权进程读到的安装载荷与主进程不同。", L"请重新下载官方安装器。",
     ExitCode::PayloadInvalid},
    {L"INSTALLER_APP_RUNNING", L"优计主义仍在运行",
     L"安装前需要先关闭应用，Windows 才能替换正在使用的文件。",
     L"请保存工作并退出应用（包括托盘图标），然后点“重新检测”。",
     ExitCode::AppRunning},
    {L"INSTALLER_UNSUPPORTED_WINDOWS", L"系统版本过低",
     L"这个版本需要 Windows 10 版本 1809 或更高。", L"请升级 Windows 后再安装。",
     ExitCode::Unsupported},
    {L"INSTALLER_UNSUPPORTED_ARCH", L"系统架构不支持",
     L"这个安装器只支持 64 位 Windows。", L"请改用 64 位设备或便携版。",
     ExitCode::Unsupported},
    {L"INSTALLER_DISK_SPACE", L"磁盘空间不足",
     L"临时目录所在磁盘的可用空间不足。", L"请清理磁盘后重试。",
     ExitCode::Unsupported},
    {L"INSTALLER_TEMP_UNAVAILABLE", L"无法使用临时目录",
     L"安装器无法创建受保护的临时目录。", L"请检查 TEMP 目录权限后重试。",
     ExitCode::Unsupported},
    {L"INSTALLER_PACKAGE_MANAGER_UNAVAILABLE", L"应用部署服务不可用",
     L"Windows 的应用部署服务暂时无法访问。", L"请重启电脑后重试。",
     ExitCode::Unsupported},
    {L"INSTALLER_DEPLOY_FAILED", L"安装失败，旧版本仍然可用",
     L"Windows 未能完成这次安装；此前安装的版本没有被移除。",
     L"请根据日志中的编号排查后重试。",
     ExitCode::DeploymentFailedOldPreserved},
    {L"INSTALLER_DEPLOY_FAILED_NOT_INSTALLED", L"安装失败，目标版本未安装",
     L"Windows 报告部署失败，并且目标版本没有出现在已安装列表中。",
     L"请打开日志查看错误编号并重试。",
     ExitCode::DeploymentFailedNotInstalled},
    {L"INSTALLER_DOWNGRADE_REJECTED", L"已安装更高版本",
     L"这台电脑上已经安装了比这个安装器更新的版本。",
     L"请使用最新版本；确需降级时先在“设置 → 应用”中卸载。",
     ExitCode::DowngradeRejected},
    {L"INSTALLER_IDENTITY_CONFLICT", L"检测到不兼容的同名应用",
     L"已安装的包与这个安装器身份相同，但发布者或签名者不同。",
     L"请不要在普通界面强行替换；先卸载不兼容的包。",
     ExitCode::IdentityConflict},
    {L"INSTALLER_LAUNCH_FAILED", L"已安装，但自动启动失败",
     L"安装已经成功，只是没能自动启动应用。",
     L"请从开始菜单打开“优计主义”。", ExitCode::LaunchFailed},
    {L"INSTALLER_STATE_INDETERMINATE", L"系统状态暂不明确",
     L"Windows 没有返回可以确认的安装结果。",
     L"请重启电脑，然后从开始菜单确认应用是否可以打开。",
     ExitCode::Indeterminate},
    {L"INSTALLER_INTERNAL_ERROR", L"安装器遇到未预期的问题",
     L"安装器内部发生了未分类的错误。", L"请打开日志并反馈。",
     ExitCode::Internal},
    {L"INSTALLER_ALREADY_RUNNING", L"安装器已经在运行",
     L"另一个安装器窗口正在处理安装。", L"请切换到已打开的安装器窗口完成安装。",
     ExitCode::Unsupported},
    {L"INSTALLER_PENDING_RESTART", L"系统需要重启",
     L"Windows 还有未完成的更新或卸载操作，需要重启后才能继续。",
     L"请重启电脑后再运行安装器。", ExitCode::Indeterminate},
};

}  // namespace

ErrorDescription DescribeError(ErrorCode code) {
  constexpr size_t count = std::size(kDescriptions);
  const size_t index = static_cast<size_t>(code);
  if (index < count) return kDescriptions[index];
  return kDescriptions[count - 1];
}

ErrorCode ErrorFromStableCode(const std::wstring& stable_code) {
  if (stable_code.empty()) return ErrorCode::Internal;
  const std::wstring& code = stable_code;
  auto equals = [&code](const wchar_t* candidate) {
    return _wcsicmp(code.c_str(), candidate) == 0;
  };
  if (equals(L"UPDATE_PACKAGE_SIGNATURE_MISSING") ||
      equals(L"UPDATE_PACKAGE_SIGNATURE_INVALID")) {
    return ErrorCode::SignatureInvalid;
  }
  if (equals(L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED")) {
    return ErrorCode::CertificateUntrusted;
  }
  if (equals(L"UPDATE_PACKAGE_PUBLISHER_MISMATCH")) {
    return ErrorCode::PublisherMismatch;
  }
  if (equals(L"UPDATE_PACKAGE_IDENTITY_MISMATCH")) {
    return ErrorCode::IdentityMismatch;
  }
  if (equals(L"UPDATE_PACKAGE_VERSION_MISMATCH")) {
    return ErrorCode::VersionMismatch;
  }
  if (equals(L"UPDATE_PACKAGE_ARCH_MISMATCH")) {
    return ErrorCode::ArchitectureMismatch;
  }
  if (equals(L"UPDATE_PACKAGE_FORMAT_INVALID")) {
    return ErrorCode::MetadataInvalid;
  }
  if (equals(L"INSTALLER_DEPLOY_PACKAGE_IN_USE")) {
    return ErrorCode::AppRunning;
  }
  if (equals(L"INSTALLER_DEPLOY_DOWNGRADE_REJECTED")) {
    return ErrorCode::DowngradeRejected;
  }
  if (equals(L"INSTALLER_DEPLOY_PENDING_RESTART")) {
    return ErrorCode::Indeterminate;
  }
  if (equals(L"INSTALLER_DEPLOY_CERTIFICATE_UNTRUSTED") ||
      equals(L"INSTALLER_DEPLOY_CERTIFICATE_CHAIN") ||
      equals(L"INSTALLER_DEPLOY_CERTIFICATE_DISTRUSTED")) {
    return ErrorCode::CertificateUntrusted;
  }
  if (equals(L"INSTALLER_DEPLOY_FAILED_NOT_INSTALLED")) {
    return ErrorCode::DeploymentFailedNotInstalled;
  }
  if (equals(L"INSTALLER_DEPLOY_ALREADY_INSTALLED")) {
    return ErrorCode::DeploymentFailed;
  }
  return ErrorCode::DeploymentFailed;
}

}  // namespace planner::installer
