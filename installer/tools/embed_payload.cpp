// 把最终 MSIX、公开证书与元数据写进 Setup EXE 的 RCDATA 资源（规格 §14.1 第 7 步）。
//
// 只做资源写入：不签名、不改清单、不联网。签名必须在嵌入之后进行，签名后禁止再改文件。
//
// 用法：
//   embed_payload.exe --stub <stub.exe> --output <Setup.exe> --msix <x.msix>
//                     --certificate <x.cer> --metadata <metadata.json>
#include <windows.h>
#include <shellapi.h>

#include <cstdio>
#include <string>
#include <vector>

#include "native_shared/text.h"
#include "payload_reader.h"

namespace {

constexpr WORD kPackageResource = 101;
constexpr WORD kCertificateResource = 102;
constexpr WORD kMetadataResource = 103;

bool ReadFileBytes(const std::wstring& path, std::vector<BYTE>& out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart > (1LL << 32)) {
    CloseHandle(file);
    return false;
  }
  out.resize(static_cast<size_t>(size.QuadPart));
  size_t offset = 0;
  while (offset < out.size()) {
    const DWORD chunk = static_cast<DWORD>(
        (out.size() - offset) > (1u << 20) ? (1u << 20) : (out.size() - offset));
    DWORD read = 0;
    if (!ReadFile(file, out.data() + offset, chunk, &read, nullptr) || read == 0) {
      CloseHandle(file);
      return false;
    }
    offset += read;
  }
  CloseHandle(file);
  return true;
}

std::wstring Argument(const std::vector<std::wstring>& arguments,
                      const wchar_t* name) {
  for (size_t index = 0; index + 1 < arguments.size(); ++index) {
    if (_wcsicmp(arguments[index].c_str(), name) == 0) return arguments[index + 1];
  }
  return {};
}

std::vector<std::wstring> Arguments() {
  int count = 0;
  LPWSTR* raw = CommandLineToArgvW(GetCommandLineW(), &count);
  std::vector<std::wstring> arguments;
  if (raw == nullptr) return arguments;
  for (int index = 1; index < count; ++index) arguments.emplace_back(raw[index]);
  LocalFree(raw);
  return arguments;
}

}  // namespace

int wmain() {
  SetConsoleOutputCP(CP_UTF8);
  const auto arguments = Arguments();
  const std::wstring stub = Argument(arguments, L"--stub");
  const std::wstring output = Argument(arguments, L"--output");
  const std::wstring msix = Argument(arguments, L"--msix");
  const std::wstring certificate = Argument(arguments, L"--certificate");
  const std::wstring metadata = Argument(arguments, L"--metadata");
  if (stub.empty() || output.empty() || msix.empty() || certificate.empty() ||
      metadata.empty()) {
    std::printf(
        "usage: embed_payload --stub <exe> --output <exe> --msix <file> "
        "--certificate <cer> --metadata <json>\n");
    return 2;
  }

  std::vector<BYTE> package_bytes;
  std::vector<BYTE> certificate_bytes;
  std::vector<BYTE> metadata_bytes;
  if (!ReadFileBytes(msix, package_bytes) ||
      !ReadFileBytes(certificate, certificate_bytes) ||
      !ReadFileBytes(metadata, metadata_bytes)) {
    std::printf("{\"ok\":false,\"error\":\"read-input\"}\n");
    return 3;
  }
  if (package_bytes.empty() || certificate_bytes.empty() ||
      metadata_bytes.empty()) {
    std::printf("{\"ok\":false,\"error\":\"empty-input\"}\n");
    return 3;
  }
  if (!CopyFileW(stub.c_str(), output.c_str(), FALSE)) {
    std::printf("{\"ok\":false,\"error\":\"copy-stub\"}\n");
    return 3;
  }

  HANDLE update = BeginUpdateResourceW(output.c_str(), FALSE);
  if (update == nullptr) {
    std::printf("{\"ok\":false,\"error\":\"begin-update\"}\n");
    return 3;
  }
  // 参数顺序是 (hUpdate, lpType, lpName, ...)：资源类型固定为 RT_RCDATA，
  // 名字才是 101/102/103。写反会得到"类型=101、名字=10"的资源，安装器读不到。
  const bool written =
      UpdateResourceW(update, RT_RCDATA, MAKEINTRESOURCEW(kPackageResource),
                      MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL),
                      package_bytes.data(),
                      static_cast<DWORD>(package_bytes.size())) &&
      UpdateResourceW(update, RT_RCDATA, MAKEINTRESOURCEW(kCertificateResource),
                      MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL),
                      certificate_bytes.data(),
                      static_cast<DWORD>(certificate_bytes.size())) &&
      UpdateResourceW(update, RT_RCDATA, MAKEINTRESOURCEW(kMetadataResource),
                      MAKELANGID(LANG_NEUTRAL, SUBLANG_NEUTRAL),
                      metadata_bytes.data(),
                      static_cast<DWORD>(metadata_bytes.size()));
  if (!written) {
    EndUpdateResourceW(update, TRUE);
    DeleteFileW(output.c_str());
    std::printf("{\"ok\":false,\"error\":\"update-resource\"}\n");
    return 3;
  }
  if (!EndUpdateResourceW(update, FALSE)) {
    DeleteFileW(output.c_str());
    std::printf("{\"ok\":false,\"error\":\"end-update\"}\n");
    return 3;
  }

  std::vector<BYTE> metadata_digest;
  std::vector<BYTE> package_digest;
  planner::native::Sha256Bytes(metadata_bytes.data(), metadata_bytes.size(),
                               metadata_digest);
  planner::native::Sha256Bytes(package_bytes.data(), package_bytes.size(),
                               package_digest);
  WIN32_FILE_ATTRIBUTE_DATA attributes{};
  std::uint64_t size = 0;
  if (GetFileAttributesExW(output.c_str(), GetFileExInfoStandard, &attributes)) {
    size = (static_cast<std::uint64_t>(attributes.nFileSizeHigh) << 32) |
           attributes.nFileSizeLow;
  }
  std::printf(
      "{\"ok\":true,\"output\":\"%s\",\"size\":%llu,"
      "\"metadataSha256\":\"%s\",\"packageSha256\":\"%s\"}\n",
      planner::native::Utf8FromWide(output).c_str(),
      static_cast<unsigned long long>(size),
      planner::native::Utf8FromWide(
          planner::native::HexEncode(metadata_digest))
          .c_str(),
      planner::native::Utf8FromWide(
          planner::native::HexEncode(package_digest))
          .c_str());
  return 0;
}
