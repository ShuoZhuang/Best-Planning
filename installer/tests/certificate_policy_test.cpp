#include <windows.h>

#include <string>
#include <vector>

#include "certificate_manager.h"
#include "native_shared/package_inspector.h"
#include "native_shared/planner_identity.h"
#include "native_shared/text.h"
#include "test_support.h"

namespace {

bool LoadFileBytes(const std::wstring& path, std::vector<BYTE>& out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart > (1LL << 20)) {
    CloseHandle(file);
    return false;
  }
  out.resize(static_cast<size_t>(size.QuadPart));
  DWORD read = 0;
  const bool ok = ReadFile(file, out.data(), static_cast<DWORD>(out.size()),
                           &read, nullptr) != FALSE &&
                  read == out.size();
  CloseHandle(file);
  return ok;
}

}  // namespace

TEST(certificate_parses_subject_and_hashes) {
  if (installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP certificate_parses_subject_and_hashes (no fixture)\n");
    return;
  }
  std::vector<BYTE> der;
  EXPECT_TRUE(LoadFileBytes(installer_tests::g_certificate_path, der));
  planner::installer::CertificateInfo info;
  std::wstring error;
  EXPECT_TRUE(planner::installer::ParseCertificate(der, info, error));
  EXPECT_TRUE(planner::native::SamePublisher(info.subject,
                                             planner::native::kPublisher));
  EXPECT_INT_EQ(40, static_cast<int>(info.thumbprint.size()));
  EXPECT_INT_EQ(64, static_cast<int>(info.sha256.size()));
  EXPECT_INT_EQ(64, static_cast<int>(info.public_key_sha256.size()));
  EXPECT_FALSE(info.expired);
  for (wchar_t character : info.thumbprint) {
    const bool hex = (character >= L'0' && character <= L'9') ||
                     (character >= L'A' && character <= L'F');
    EXPECT_TRUE(hex);
  }
}

TEST(certificates_with_different_keys_are_not_the_same) {
  if (installer_tests::g_certificate_path.empty() ||
      installer_tests::g_second_certificate_path.empty()) {
    std::printf("SKIP certificates_with_different_keys_are_not_the_same\n");
    return;
  }
  std::vector<BYTE> first;
  std::vector<BYTE> second;
  EXPECT_TRUE(LoadFileBytes(installer_tests::g_certificate_path, first));
  EXPECT_TRUE(LoadFileBytes(installer_tests::g_second_certificate_path, second));
  EXPECT_FALSE(planner::native::SameCertificate(first, second));
  EXPECT_FALSE(first == second);

  planner::installer::CertificateInfo first_info;
  planner::installer::CertificateInfo second_info;
  std::wstring error;
  EXPECT_TRUE(planner::installer::ParseCertificate(first, first_info, error));
  EXPECT_TRUE(planner::installer::ParseCertificate(second, second_info, error));
  EXPECT_FALSE(first_info.thumbprint == second_info.thumbprint);
  EXPECT_FALSE(first_info.public_key_sha256 == second_info.public_key_sha256);
  EXPECT_TRUE(planner::native::SameCertificate(first, first));
}

TEST(empty_certificate_is_rejected) {
  planner::installer::CertificateInfo info;
  std::wstring error;
  EXPECT_FALSE(planner::installer::ParseCertificate({}, info, error));
}

TEST(certificate_store_query_is_available) {
  if (installer_tests::g_certificate_path.empty()) {
    std::printf("SKIP certificate_store_query_is_available (no fixture)\n");
    return;
  }
  std::vector<BYTE> der;
  EXPECT_TRUE(LoadFileBytes(installer_tests::g_certificate_path, der));
  bool present = false;
  std::wstring error;
  EXPECT_TRUE(planner::installer::IsTrustedForSideloading(der, present, error));
  // 本机是否已导入不影响正确性：查询本身必须成功。
  EXPECT_WSTRING_EQ(L"", error);
}

TEST(existing_certificate_is_never_removed) {
  std::vector<BYTE> der;
  if (!installer_tests::g_certificate_path.empty()) {
    EXPECT_TRUE(LoadFileBytes(installer_tests::g_certificate_path, der));
  }
  std::wstring reason;
  EXPECT_FALSE(planner::installer::CanSafelyRemoveCertificate(der, true, reason));
  EXPECT_WSTRING_EQ(L"certificate-existed-before", reason);
}

TEST(unrelated_certificate_is_never_removed) {
  if (installer_tests::g_second_certificate_path.empty()) {
    std::printf("SKIP unrelated_certificate_is_never_removed (no fixture)\n");
    return;
  }
  std::vector<BYTE> der;
  EXPECT_TRUE(LoadFileBytes(installer_tests::g_second_certificate_path, der));
  std::wstring reason;
  // 主题不是固定发布者，或仍有包登记：两种理由都必须拒绝删除。
  EXPECT_FALSE(planner::installer::CanSafelyRemoveCertificate(der, false, reason));
  EXPECT_FALSE(reason.empty());
}
