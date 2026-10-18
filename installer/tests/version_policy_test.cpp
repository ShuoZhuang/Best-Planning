#include <string>

#include "native_shared/planner_identity.h"
#include "payload_metadata.h"
#include "test_support.h"

namespace {

namespace nh = planner::native;
using planner::installer::PayloadMetadata;

PayloadMetadata ValidMetadata() {
  PayloadMetadata metadata;
  metadata.schema_version = 1;
  metadata.installer_version = L"1.10.0+47";
  metadata.app_version = L"1.10.0+47";
  metadata.msix_version = L"1.10.0.0";
  metadata.identity_name = nh::kIdentityName;
  metadata.publisher = nh::kPublisher;
  metadata.family_name = nh::PackageFamilyName(nh::kIdentityName, nh::kPublisher);
  metadata.architecture = L"x64";
  metadata.package_size = 18 * 1024 * 1024;
  metadata.package_sha256 = std::wstring(64, L'a');
  metadata.certificate_sha256 = std::wstring(64, L'b');
  metadata.certificate_thumbprint = std::wstring(40, L'C');
  metadata.minimum_windows_build = 17763;
  metadata.asset_file_name = L"BestPlanning_1.10.0.0_x64.msix";
  return metadata;
}

}  // namespace

TEST(version_parsing_and_ordering) {
  nh::PackageVersion newer;
  nh::PackageVersion older;
  nh::PackageVersion same;
  EXPECT_TRUE(nh::PackageVersion::Parse(L"1.10.0.0", newer));
  EXPECT_TRUE(nh::PackageVersion::Parse(L"1.9.1.0", older));
  EXPECT_TRUE(nh::PackageVersion::Parse(L"1.10.0.0", same));
  EXPECT_TRUE(newer == same);
  EXPECT_TRUE(newer.IsHigherThan(older));
  EXPECT_FALSE(older.IsHigherThan(newer));
  EXPECT_WSTRING_EQ(L"1.10.0.0", newer.ToString());
  EXPECT_FALSE(nh::PackageVersion::Parse(L"1.10.0", newer));
  EXPECT_FALSE(nh::PackageVersion::Parse(L"one.two", newer));
}

TEST(version_encoding_round_trips) {
  nh::PackageVersion version;
  EXPECT_TRUE(nh::PackageVersion::Parse(L"1.2.3.4", version));
  const auto encoded = version.Encode();
  const auto decoded = nh::PackageVersion::FromEncoded(encoded);
  EXPECT_WSTRING_EQ(L"1.2.3.4", decoded.ToString());
  EXPECT_INT_EQ(0x0001000200030004LL, static_cast<long long>(encoded));
}

TEST(downgrade_is_detected) {
  nh::PackageVersion installed;
  nh::PackageVersion target;
  EXPECT_TRUE(nh::PackageVersion::Parse(L"1.10.1.0", installed));
  EXPECT_TRUE(nh::PackageVersion::Parse(L"1.10.0.0", target));
  EXPECT_TRUE(installed.IsHigherThan(target));
  EXPECT_FALSE(target.IsHigherThan(installed));
}

TEST(publisher_and_family_name) {
  EXPECT_TRUE(nh::SamePublisher(nh::kPublisher,
                                L"CN=Shuo Zhuang,O=Personal User,C=CN"));
  EXPECT_TRUE(nh::SamePublisher(L"cn=shuo zhuang, o=personal user, c=cn",
                                nh::kPublisher));
  EXPECT_FALSE(nh::SamePublisher(nh::kPublisher,
                                 L"CN=Someone Else, O=Personal User, C=CN"));
  EXPECT_FALSE(nh::SamePublisher(nh::kPublisher, L""));
  EXPECT_WSTRING_EQ(L"ShuoZhuang.PersonalPlanner_v9555qkaxdyym",
                    nh::PackageFamilyName(nh::kIdentityName, nh::kPublisher));
}

TEST(architecture_comparison) {
  EXPECT_TRUE(nh::SameArchitecture(L"x64", L"X64"));
  EXPECT_FALSE(nh::SameArchitecture(L"x64", L"arm64"));
  EXPECT_FALSE(nh::SameArchitecture(L"x64", L""));
}

TEST(metadata_accepts_valid_payload_description) {
  auto metadata = ValidMetadata();
  std::wstring failure;
  EXPECT_TRUE(metadata.Validate(failure));
  EXPECT_WSTRING_EQ(L"", failure);
}

TEST(metadata_rejects_wrong_schema) {
  auto metadata = ValidMetadata();
  metadata.schema_version = 2;
  std::wstring failure;
  EXPECT_FALSE(metadata.Validate(failure));
  EXPECT_WSTRING_EQ(L"INSTALLER_METADATA_VERSION_UNSUPPORTED", failure);
}

TEST(metadata_rejects_identity_publisher_architecture) {
  std::wstring failure;
  {
    auto metadata = ValidMetadata();
    metadata.identity_name = L"Someone.Else";
    EXPECT_FALSE(metadata.Validate(failure));
    EXPECT_WSTRING_EQ(L"INSTALLER_METADATA_IDENTITY_MISMATCH", failure);
  }
  {
    auto metadata = ValidMetadata();
    metadata.publisher = L"CN=Someone Else, O=Personal User, C=CN";
    EXPECT_FALSE(metadata.Validate(failure));
    EXPECT_WSTRING_EQ(L"INSTALLER_METADATA_PUBLISHER_MISMATCH", failure);
  }
  {
    auto metadata = ValidMetadata();
    metadata.family_name = L"ShuoZhuang.PersonalPlanner_deadbeefdeadb";
    EXPECT_FALSE(metadata.Validate(failure));
    EXPECT_WSTRING_EQ(L"INSTALLER_METADATA_FAMILY_MISMATCH", failure);
  }
  {
    auto metadata = ValidMetadata();
    metadata.architecture = L"arm64";
    EXPECT_FALSE(metadata.Validate(failure));
    EXPECT_WSTRING_EQ(L"INSTALLER_METADATA_ARCH_MISMATCH", failure);
  }
}

TEST(metadata_rejects_bad_hashes_and_sizes) {
  std::wstring failure;
  {
    auto metadata = ValidMetadata();
    metadata.package_sha256 = std::wstring(63, L'a');
    EXPECT_FALSE(metadata.Validate(failure));
  }
  {
    auto metadata = ValidMetadata();
    metadata.certificate_thumbprint = std::wstring(39, L'C');
    EXPECT_FALSE(metadata.Validate(failure));
  }
  {
    auto metadata = ValidMetadata();
    metadata.package_size = 0;
    EXPECT_FALSE(metadata.Validate(failure));
  }
  {
    auto metadata = ValidMetadata();
    metadata.msix_version = L"1.10.0";
    EXPECT_FALSE(metadata.Validate(failure));
  }
  {
    auto metadata = ValidMetadata();
    metadata.minimum_windows_build = 0;
    EXPECT_FALSE(metadata.Validate(failure));
  }
}

TEST(metadata_json_round_trip) {
  auto metadata = ValidMetadata();
  const std::wstring json = metadata.ToJson();
  std::vector<BYTE> bytes(json.begin(), json.end());
  PayloadMetadata parsed;
  std::wstring failure;
  EXPECT_TRUE(PayloadMetadata::Parse(bytes, parsed, failure));
  EXPECT_WSTRING_EQ(metadata.msix_version, parsed.msix_version);
  EXPECT_WSTRING_EQ(metadata.package_sha256, parsed.package_sha256);
  EXPECT_INT_EQ(static_cast<long long>(metadata.package_size),
                static_cast<long long>(parsed.package_size));
  EXPECT_TRUE(!parsed.RawSha256().empty());
}

TEST(metadata_rejects_garbage) {
  PayloadMetadata parsed;
  std::wstring failure;
  const std::string garbage = "not json";
  std::vector<BYTE> bytes(garbage.begin(), garbage.end());
  EXPECT_FALSE(PayloadMetadata::Parse(bytes, parsed, failure));
  std::vector<BYTE> empty;
  EXPECT_FALSE(PayloadMetadata::Parse(empty, parsed, failure));
  EXPECT_WSTRING_EQ(L"INSTALLER_METADATA_MISSING", failure);
}
