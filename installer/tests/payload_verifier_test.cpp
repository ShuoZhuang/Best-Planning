#include <windows.h>

#include <string>
#include <vector>

#include "certificate_manager.h"
#include "native_shared/package_inspector.h"
#include "native_shared/planner_identity.h"
#include "native_shared/text.h"
#include "package_verifier.h"
#include "payload_metadata.h"
#include "test_support.h"

namespace {

namespace nh = planner::native;
using planner::installer::CertificateInfo;
using planner::installer::PayloadMetadata;
using planner::installer::VerificationOutcome;
using planner::installer::VerifyCertificateMetadata;
using planner::installer::VerifyPayloadFile;

bool LoadFileBytes(const std::wstring& path, std::vector<BYTE>& out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart > (1LL << 31)) {
    CloseHandle(file);
    return false;
  }
  out.resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool ok = ReadFile(file, out.data(), static_cast<DWORD>(out.size()),
                           &read, nullptr) != FALSE &&
                  read == out.size();
  CloseHandle(file);
  if (!ok) out.clear();
  return ok;
}

std::wstring TemporaryCopy(const std::wstring& source, const std::wstring& suffix,
                           bool append_byte, size_t corrupt_offset) {
  wchar_t temp[MAX_PATH + 1]{};
  if (GetTempPathW(MAX_PATH, temp) == 0) return {};
  wchar_t name[64]{};
  swprintf_s(name, L"installer-test-%lu%s", GetCurrentProcessId(), suffix.c_str());
  const std::wstring target = std::wstring(temp) + name;
  std::vector<BYTE> bytes;
  if (!LoadFileBytes(source, bytes) || bytes.empty()) return {};
  if (append_byte) {
    bytes.push_back(0x00);
  } else if (corrupt_offset < bytes.size()) {
    bytes[corrupt_offset] ^= 0xFF;
  }
  HANDLE file = CreateFileW(target.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  DWORD written = 0;
  WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written,
            nullptr);
  CloseHandle(file);
  return written == bytes.size() ? target : std::wstring{};
}

void RemoveQuietly(const std::wstring& path) {
  if (!path.empty()) DeleteFileW(path.c_str());
}

bool BuildMetadata(const std::wstring& msix, const std::wstring& certificate,
                   PayloadMetadata& metadata, std::vector<BYTE>& cert_der) {
  if (msix.empty() || certificate.empty()) return false;
  if (!LoadFileBytes(certificate, cert_der) || cert_der.empty()) return false;
  CertificateInfo info;
  std::wstring error;
  if (!planner::installer::ParseCertificate(cert_der, info, error)) return false;

  WIN32_FILE_ATTRIBUTE_DATA attributes{};
  if (!GetFileAttributesExW(msix.c_str(), GetFileExInfoStandard, &attributes)) {
    return false;
  }
  std::vector<BYTE> digest;
  if (!nh::Sha256File(msix, digest)) return false;

  const auto inspection = nh::InspectPackage(msix, nh::SignatureCheck::None);
  if (!inspection.ok) return false;

  metadata.schema_version = 1;
  metadata.installer_version = L"1.10.0+47";
  metadata.app_version = L"1.10.0+47";
  metadata.msix_version = inspection.identity.VersionString();
  metadata.identity_name = inspection.identity.name;
  metadata.publisher = inspection.identity.publisher;
  metadata.family_name = inspection.identity.family_name;
  metadata.architecture = inspection.identity.architecture;
  metadata.package_size =
      (static_cast<std::uint64_t>(attributes.nFileSizeHigh) << 32) |
      attributes.nFileSizeLow;
  metadata.package_sha256 = nh::HexEncode(digest);
  metadata.certificate_sha256 = info.sha256;
  metadata.certificate_thumbprint = info.thumbprint;
  metadata.minimum_windows_build = 17763;
  metadata.asset_file_name = L"BestPlanning_test_x64.msix";
  std::wstring failure;
  return metadata.Validate(failure);
}

}  // namespace

TEST(payload_verifier_accepts_the_real_package) {
  if (installer_tests::g_msix_path.empty() ||
      installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP payload_verifier_accepts_the_real_package (no fixtures)\n");
    return;
  }
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  EXPECT_TRUE(BuildMetadata(installer_tests::g_msix_path,
                            installer_tests::g_certificate_path, metadata,
                            certificate));
  CertificateInfo info;
  planner::installer::ErrorCode certificate_error =
      planner::installer::ErrorCode::None;
  std::wstring certificate_detail;
  EXPECT_TRUE(VerifyCertificateMetadata(metadata, certificate, info,
                                        certificate_error, certificate_detail));
  const auto outcome = VerifyPayloadFile(
      metadata, certificate, installer_tests::g_msix_path, false);
  EXPECT_TRUE(outcome.ok);
  EXPECT_WSTRING_EQ(metadata.msix_version, outcome.identity.VersionString());
  EXPECT_WSTRING_EQ(metadata.package_sha256, outcome.package_sha256);
  EXPECT_INT_EQ(static_cast<long long>(metadata.package_size),
                static_cast<long long>(outcome.package_size));
}

TEST(payload_verifier_rejects_appended_bytes) {
  if (installer_tests::g_msix_path.empty() ||
      installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP payload_verifier_rejects_appended_bytes (no fixtures)\n");
    return;
  }
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  EXPECT_TRUE(BuildMetadata(installer_tests::g_msix_path,
                            installer_tests::g_certificate_path, metadata,
                            certificate));
  const std::wstring tampered =
      TemporaryCopy(installer_tests::g_msix_path, L".appended.msix", true, 0);
  EXPECT_FALSE(tampered.empty());
  const auto outcome = VerifyPayloadFile(metadata, certificate, tampered, false);
  EXPECT_FALSE(outcome.ok);
  EXPECT_TRUE(outcome.error == planner::installer::ErrorCode::PayloadSizeMismatch);
  RemoveQuietly(tampered);
}

TEST(payload_verifier_rejects_corrupted_bytes) {
  if (installer_tests::g_msix_path.empty() ||
      installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP payload_verifier_rejects_corrupted_bytes (no fixtures)\n");
    return;
  }
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  EXPECT_TRUE(BuildMetadata(installer_tests::g_msix_path,
                            installer_tests::g_certificate_path, metadata,
                            certificate));
  const size_t offset = static_cast<size_t>(metadata.package_size / 2);
  const std::wstring tampered =
      TemporaryCopy(installer_tests::g_msix_path, L".corrupted.msix", false,
                    offset);
  EXPECT_FALSE(tampered.empty());
  const auto outcome = VerifyPayloadFile(metadata, certificate, tampered, false);
  EXPECT_FALSE(outcome.ok);
  EXPECT_TRUE(outcome.error == planner::installer::ErrorCode::PayloadHashMismatch);
  RemoveQuietly(tampered);
}

TEST(payload_verifier_rejects_a_different_certificate) {
  if (installer_tests::g_msix_path.empty() ||
      installer_tests::g_certificate_path.empty() ||
      installer_tests::g_second_certificate_path.empty()) {
    std::printf(
        "SKIP payload_verifier_rejects_a_different_certificate (no fixtures)\n");
    return;
  }
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  EXPECT_TRUE(BuildMetadata(installer_tests::g_msix_path,
                            installer_tests::g_certificate_path, metadata,
                            certificate));
  std::vector<BYTE> other_certificate;
  EXPECT_TRUE(
      LoadFileBytes(installer_tests::g_second_certificate_path, other_certificate));
  const auto outcome = VerifyPayloadFile(metadata, other_certificate,
                                         installer_tests::g_msix_path, false);
  EXPECT_FALSE(outcome.ok);
  EXPECT_TRUE(outcome.error == planner::installer::ErrorCode::SignatureInvalid);
}

TEST(payload_verifier_rejects_version_mismatch) {
  if (installer_tests::g_msix_path.empty() ||
      installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP payload_verifier_rejects_version_mismatch (no fixtures)\n");
    return;
  }
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  EXPECT_TRUE(BuildMetadata(installer_tests::g_msix_path,
                            installer_tests::g_certificate_path, metadata,
                            certificate));
  metadata.msix_version = L"9.9.9.9";
  const auto outcome = VerifyPayloadFile(
      metadata, certificate, installer_tests::g_msix_path, false);
  EXPECT_FALSE(outcome.ok);
  EXPECT_TRUE(outcome.error == planner::installer::ErrorCode::VersionMismatch);
}

TEST(payload_verifier_rejects_missing_file) {
  PayloadMetadata metadata;
  metadata.schema_version = 1;
  metadata.installer_version = L"1.10.0+47";
  metadata.app_version = L"1.10.0+47";
  metadata.msix_version = L"1.10.0.0";
  metadata.identity_name = nh::kIdentityName;
  metadata.publisher = nh::kPublisher;
  metadata.family_name = nh::PackageFamilyName(nh::kIdentityName, nh::kPublisher);
  metadata.architecture = L"x64";
  metadata.package_size = 10;
  metadata.package_sha256 = std::wstring(64, L'a');
  metadata.certificate_sha256 = std::wstring(64, L'b');
  metadata.certificate_thumbprint = std::wstring(40, L'C');
  metadata.minimum_windows_build = 17763;
  metadata.asset_file_name = L"missing.msix";
  const auto outcome = VerifyPayloadFile(metadata, {}, L"C:\\does-not-exist.msix",
                                         false);
  EXPECT_FALSE(outcome.ok);
  EXPECT_TRUE(outcome.error == planner::installer::ErrorCode::PayloadMissing);
}

TEST(certificate_metadata_mismatch_is_rejected) {
  if (installer_tests::g_msix_path.empty() ||
      installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP certificate_metadata_mismatch_is_rejected (no fixtures)\n");
    return;
  }
  PayloadMetadata metadata;
  std::vector<BYTE> certificate;
  EXPECT_TRUE(BuildMetadata(installer_tests::g_msix_path,
                            installer_tests::g_certificate_path, metadata,
                            certificate));
  metadata.certificate_sha256 = std::wstring(64, L'0');
  CertificateInfo info;
  planner::installer::ErrorCode error = planner::installer::ErrorCode::None;
  std::wstring detail;
  EXPECT_FALSE(VerifyCertificateMetadata(metadata, certificate, info, error,
                                         detail));
  EXPECT_TRUE(error == planner::installer::ErrorCode::PayloadHashMismatch);
}
