// 安装日志（规格 §12）。
//
// 只记录诊断事实：版本、状态转换、校验结果、部署错误码、证书动作、最终状态。
// 不记录任务/课程/偏好内容，不记录私钥或密码，不自动上传。
#pragma once

#include <string>
#include <mutex>

namespace planner::installer {

class InstallerLogger {
 public:
  InstallerLogger() = default;
  ~InstallerLogger();

  bool Open(std::wstring& error);
  void Line(const std::wstring& text);
  void StateChange(const std::wstring& from, const std::wstring& to);
  void Failure(const std::wstring& code, const std::wstring& detail);

  const std::wstring& path() const { return path_; }
  const std::wstring& directory() const { return directory_; }
  bool opened() const { return opened_; }

 private:
  void Rotate();

  std::mutex mutex_;
  std::wstring directory_;
  std::wstring path_;
  bool opened_ = false;
};

}  // namespace planner::installer
