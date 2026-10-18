// 受保护的临时会话（规格 §8.4）。
//
// 会话目录名来自密码学随机数，ACL 只允许当前用户、SYSTEM 与管理员，
// 文件排他创建，拒绝重解析点，令牌只能使用一次。
#pragma once

#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

namespace planner::installer {

class SecureSession {
 public:
  SecureSession() = default;
  ~SecureSession();

  SecureSession(const SecureSession&) = delete;
  SecureSession& operator=(const SecureSession&) = delete;

  bool Create(std::wstring& error);
  bool WriteFile(const wchar_t* name, const void* data, size_t size,
                 std::wstring& error);
  bool ReadFile(const wchar_t* name, std::vector<BYTE>& out,
                std::wstring& error) const;

  std::wstring FilePath(const wchar_t* name) const;
  const std::wstring& directory() const { return directory_; }
  bool created() const { return !directory_.empty(); }

  // 一次性会话令牌：协商用的 nonce（32 字节）。
  std::vector<BYTE> IssueToken();
  bool ConsumeToken(const std::vector<BYTE>& token);

  bool Cleanup(std::wstring& error);

 private:
  std::wstring directory_;
  std::vector<BYTE> token_;
  bool token_issued_ = false;
  bool token_consumed_ = false;
};

}  // namespace planner::installer
