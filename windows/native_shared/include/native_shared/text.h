// 共享基础工具：UTF 转换、十六进制、SHA-256、路径边界。
//
// 这些函数同时被更新助手与安装器使用；两份实现漂移会直接变成安全缺陷，
// 因此只允许存在这一份（规格 §7.3、§15）。
#pragma once

#include <windows.h>

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace planner::native {

std::string Utf8FromWide(const std::wstring& value);
std::wstring WideFromUtf8(const std::string& value);

std::wstring HexEncode(const std::vector<BYTE>& bytes);
bool HexEquals(const std::wstring& hex, const std::vector<BYTE>& bytes);
bool IsHex(const std::wstring& value, size_t length);

bool Sha256Bytes(const void* data, size_t size, std::vector<BYTE>& digest);
bool Sha256File(const std::wstring& path, std::vector<BYTE>& digest);

// 规范路径判断：path 是否在 root 之下（按目录边界，不接受 `..` 越界）。
bool IsPathUnderRoot(const std::wstring& path, const std::wstring& root);

// 路径自身或任一祖先目录是重解析点（符号链接/连接点）时返回 true。
bool HasReparsePoint(const std::wstring& path);

}  // namespace planner::native
