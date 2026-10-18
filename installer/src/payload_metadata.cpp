#include "payload_metadata.h"

#include <winrt/Windows.Data.Json.h>

#include <cstdio>

#include "native_shared/text.h"

using winrt::Windows::Data::Json::JsonObject;
using winrt::Windows::Data::Json::JsonValue;
using winrt::Windows::Data::Json::JsonValueType;

namespace planner::installer {
namespace {

namespace nh = planner::native;

bool ReadString(const JsonObject& object, const wchar_t* name, bool required,
                std::wstring& target, std::wstring& failure) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::String) {
      if (required) failure = L"INSTALLER_METADATA_INVALID";
      return !required;
    }
    target = value.GetString().c_str();
    return true;
  } catch (...) {
    if (required) failure = L"INSTALLER_METADATA_INVALID";
    return !required;
  }
}

bool ReadNumber(const JsonObject& object, const wchar_t* name, double& target,
                std::wstring& failure) {
  try {
    const auto value = object.GetNamedValue(name);
    if (value.ValueType() != JsonValueType::Number) {
      failure = L"INSTALLER_METADATA_INVALID";
      return false;
    }
    target = value.GetNumber();
    return true;
  } catch (...) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
}

}  // namespace

planner::native::PackageVersion PayloadMetadata::MsixVersionValue() const {
  planner::native::PackageVersion version;
  planner::native::PackageVersion::Parse(msix_version, version);
  return version;
}

std::wstring PayloadMetadata::RawSha256() const {
  std::vector<BYTE> digest;
  if (!nh::Sha256Bytes(raw_json.data(), raw_json.size(), digest)) return {};
  return nh::HexEncode(digest);
}

bool PayloadMetadata::Validate(std::wstring& failure) const {
  if (schema_version != 1) {
    failure = L"INSTALLER_METADATA_VERSION_UNSUPPORTED";
    return false;
  }
  if (installer_version.empty() || app_version.empty()) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
  planner::native::PackageVersion version;
  if (!planner::native::PackageVersion::Parse(msix_version, version)) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
  if (_wcsicmp(identity_name.c_str(), nh::kIdentityName) != 0) {
    failure = L"INSTALLER_METADATA_IDENTITY_MISMATCH";
    return false;
  }
  if (!nh::SamePublisher(publisher, nh::kPublisher)) {
    failure = L"INSTALLER_METADATA_PUBLISHER_MISMATCH";
    return false;
  }
  const std::wstring expected_family =
      nh::PackageFamilyName(identity_name, publisher);
  if (expected_family.empty() || _wcsicmp(family_name.c_str(),
                                          expected_family.c_str()) != 0) {
    failure = L"INSTALLER_METADATA_FAMILY_MISMATCH";
    return false;
  }
  if (!nh::SameArchitecture(architecture, nh::kArchitecture)) {
    failure = L"INSTALLER_METADATA_ARCH_MISMATCH";
    return false;
  }
  if (package_size == 0) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
  if (!nh::IsHex(package_sha256, 64) || !nh::IsHex(certificate_sha256, 64) ||
      !nh::IsHex(certificate_thumbprint, 40)) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
  if (minimum_windows_build == 0) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
  if (asset_file_name.empty()) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }
  return true;
}

bool PayloadMetadata::Parse(const std::vector<BYTE>& utf8_json,
                            PayloadMetadata& out, std::wstring& failure) {
  out = PayloadMetadata{};
  if (utf8_json.empty()) {
    failure = L"INSTALLER_METADATA_MISSING";
    return false;
  }
  out.raw_json.assign(reinterpret_cast<const char*>(utf8_json.data()),
                      utf8_json.size());
  JsonObject object{nullptr};
  try {
    object = JsonObject::Parse(nh::WideFromUtf8(out.raw_json));
  } catch (...) {
    failure = L"INSTALLER_METADATA_INVALID";
    return false;
  }

  double schema = 0;
  double size = 0;
  double minimum_build = 0;
  if (!ReadNumber(object, L"schemaVersion", schema, failure) ||
      !ReadNumber(object, L"packageSizeBytes", size, failure) ||
      !ReadNumber(object, L"minimumWindowsBuild", minimum_build, failure)) {
    return false;
  }
  if (!ReadString(object, L"installerVersion", true, out.installer_version,
                  failure) ||
      !ReadString(object, L"appVersion", true, out.app_version, failure) ||
      !ReadString(object, L"msixVersion", true, out.msix_version, failure) ||
      !ReadString(object, L"identityName", true, out.identity_name, failure) ||
      !ReadString(object, L"publisher", true, out.publisher, failure) ||
      !ReadString(object, L"familyName", true, out.family_name, failure) ||
      !ReadString(object, L"architecture", true, out.architecture, failure) ||
      !ReadString(object, L"packageSha256", true, out.package_sha256, failure) ||
      !ReadString(object, L"certificateSha256", true, out.certificate_sha256,
                  failure) ||
      !ReadString(object, L"certificateThumbprint", true,
                  out.certificate_thumbprint, failure) ||
      !ReadString(object, L"assetFileName", true, out.asset_file_name,
                  failure)) {
    return false;
  }
  out.schema_version = static_cast<int>(schema);
  out.package_size = static_cast<std::uint64_t>(size);
  out.minimum_windows_build = static_cast<unsigned>(minimum_build);
  return out.Validate(failure);
}

std::wstring PayloadMetadata::ToJson() const {
  JsonObject object;
  object.SetNamedValue(L"schemaVersion",
                       JsonValue::CreateNumberValue(schema_version));
  object.SetNamedValue(L"installerVersion",
                       JsonValue::CreateStringValue(installer_version));
  object.SetNamedValue(L"appVersion",
                       JsonValue::CreateStringValue(app_version));
  object.SetNamedValue(L"msixVersion",
                       JsonValue::CreateStringValue(msix_version));
  object.SetNamedValue(L"identityName",
                       JsonValue::CreateStringValue(identity_name));
  object.SetNamedValue(L"publisher", JsonValue::CreateStringValue(publisher));
  object.SetNamedValue(L"familyName", JsonValue::CreateStringValue(family_name));
  object.SetNamedValue(L"architecture",
                       JsonValue::CreateStringValue(architecture));
  object.SetNamedValue(
      L"packageSizeBytes",
      JsonValue::CreateNumberValue(static_cast<double>(package_size)));
  object.SetNamedValue(L"packageSha256",
                       JsonValue::CreateStringValue(package_sha256));
  object.SetNamedValue(L"certificateSha256",
                       JsonValue::CreateStringValue(certificate_sha256));
  object.SetNamedValue(L"certificateThumbprint",
                       JsonValue::CreateStringValue(certificate_thumbprint));
  object.SetNamedValue(
      L"minimumWindowsBuild",
      JsonValue::CreateNumberValue(static_cast<double>(minimum_windows_build)));
  object.SetNamedValue(L"assetFileName",
                       JsonValue::CreateStringValue(asset_file_name));
  return object.Stringify().c_str();
}

}  // namespace planner::installer
