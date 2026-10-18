#include "payload_reader.h"

namespace planner::installer {
namespace {

bool ReadResource(WORD id, std::vector<BYTE>& out) {
  out.clear();
  HRSRC resource = FindResourceW(nullptr, MAKEINTRESOURCEW(id), RT_RCDATA);
  if (resource == nullptr) return false;
  const DWORD size = SizeofResource(nullptr, resource);
  if (size == 0) return false;
  HGLOBAL loaded = LoadResource(nullptr, resource);
  if (loaded == nullptr) return false;
  const void* data = LockResource(loaded);
  if (data == nullptr) return false;
  const BYTE* bytes = static_cast<const BYTE*>(data);
  out.assign(bytes, bytes + size);
  return true;
}

}  // namespace

bool ReadEmbeddedMetadata(PayloadMetadata& metadata, ErrorCode& error,
                          std::wstring& detail) {
  std::vector<BYTE> raw;
  if (!ReadResource(kResourceMetadata, raw)) {
    error = ErrorCode::PayloadMissing;
    detail = L"metadata-resource-missing";
    return false;
  }
  std::wstring failure;
  if (!PayloadMetadata::Parse(raw, metadata, failure)) {
    error = failure == L"INSTALLER_METADATA_VERSION_UNSUPPORTED"
                ? ErrorCode::MetadataVersionUnsupported
                : ErrorCode::MetadataInvalid;
    detail = failure;
    return false;
  }
  return true;
}

bool ReadEmbeddedPayload(EmbeddedPayload& payload, ErrorCode& error,
                         std::wstring& detail) {
  payload = EmbeddedPayload{};
  if (!ReadEmbeddedMetadata(payload.metadata, error, detail)) return false;
  if (!ReadResource(kResourceCertificate, payload.certificate) ||
      payload.certificate.empty()) {
    error = ErrorCode::PayloadMissing;
    detail = L"certificate-resource-missing";
    return false;
  }
  if (!ReadResource(kResourcePackage, payload.package) ||
      payload.package.empty()) {
    error = ErrorCode::PayloadMissing;
    detail = L"package-resource-missing";
    return false;
  }
  return true;
}

}  // namespace planner::installer
