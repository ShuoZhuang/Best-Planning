// 读取 Setup EXE 的只读载荷资源（规格 §7.2）。
//
// 资源 ID 固定，内容只有三样：最终 MSIX、公开证书、元数据。
// 提权进程也从这个 EXE 的资源里重读，不接受任何外部路径。
#pragma once

#include <windows.h>

#include <string>
#include <vector>

#include "installer_errors.h"
#include "payload_metadata.h"

namespace planner::installer {

inline constexpr WORD kResourcePackage = 101;
inline constexpr WORD kResourceCertificate = 102;
inline constexpr WORD kResourceMetadata = 103;

struct EmbeddedPayload {
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  std::vector<BYTE> package;
};

bool ReadEmbeddedPayload(EmbeddedPayload& payload, ErrorCode& error,
                         std::wstring& detail);

// 只读取元数据的原始字节与解析结果（提权进程用它核对载荷摘要）。
bool ReadEmbeddedMetadata(PayloadMetadata& metadata, ErrorCode& error,
                          std::wstring& detail);

}  // namespace planner::installer
