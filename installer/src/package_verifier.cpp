#include "package_verifier.h"

#include "native_shared/package_inspector.h"
#include "native_shared/planner_identity.h"
#include "native_shared/text.h"

namespace planner::installer {
namespace {

namespace nh = planner::native;

std::wstring VersionOf(std::uint64_t encoded) {
  return nh::PackageVersion::FromEncoded(encoded).ToString();
}

bool SameVersionText(const std::wstring& left, const std::wstring& right) {
  nh::PackageVersion a;
  nh::PackageVersion b;
  if (!nh::PackageVersion::Parse(left, a) || !nh::PackageVersion::Parse(right, b)) {
    return false;
  }
  return a == b;
}

}  // namespace

bool VerifyCertificateMetadata(const PayloadMetadata& metadata,
                               const std::vector<BYTE>& certificate,
                               CertificateInfo& info, ErrorCode& error,
                               std::wstring& detail) {
  std::wstring parse_error;
  if (!ParseCertificate(certificate, info, parse_error)) {
    error = ErrorCode::MetadataInvalid;
    detail = L"certificate " + parse_error;
    return false;
  }
  if (_wcsicmp(info.sha256.c_str(), metadata.certificate_sha256.c_str()) != 0) {
    error = ErrorCode::PayloadHashMismatch;
    detail = L"certificate-sha256";
    return false;
  }
  if (_wcsicmp(info.thumbprint.c_str(),
               metadata.certificate_thumbprint.c_str()) != 0) {
    error = ErrorCode::PayloadHashMismatch;
    detail = L"certificate-thumbprint";
    return false;
  }
  if (info.expired) {
    error = ErrorCode::MetadataInvalid;
    detail = L"certificate-expired";
    return false;
  }
  return true;
}

VerificationOutcome VerifyPayloadFile(const PayloadMetadata& metadata,
                                      const std::vector<BYTE>& certificate,
                                      const std::wstring& package_path,
                                      bool require_trust) {
  VerificationOutcome outcome;

  WIN32_FILE_ATTRIBUTE_DATA attributes{};
  if (!GetFileAttributesExW(package_path.c_str(), GetFileExInfoStandard,
                            &attributes)) {
    outcome.error = ErrorCode::PayloadMissing;
    outcome.detail = L"package-file-missing";
    return outcome;
  }
  outcome.package_size =
      (static_cast<std::uint64_t>(attributes.nFileSizeHigh) << 32) |
      attributes.nFileSizeLow;
  if (outcome.package_size != metadata.package_size) {
    outcome.error = ErrorCode::PayloadSizeMismatch;
    outcome.detail = L"size " + std::to_wstring(outcome.package_size) + L" != " +
                     std::to_wstring(metadata.package_size);
    return outcome;
  }

  std::vector<BYTE> digest;
  if (!nh::Sha256File(package_path, digest)) {
    outcome.error = ErrorCode::PayloadMissing;
    outcome.detail = L"hash-read-failed";
    return outcome;
  }
  outcome.package_sha256 = nh::HexEncode(digest);
  if (_wcsicmp(outcome.package_sha256.c_str(),
               metadata.package_sha256.c_str()) != 0) {
    outcome.error = ErrorCode::PayloadHashMismatch;
    outcome.detail = L"package-sha256";
    return outcome;
  }

  // 包清单身份：从成品里读，不信任元数据自述。
  const auto inspection = nh::InspectPackage(package_path, nh::SignatureCheck::None);
  if (!inspection.ok) {
    outcome.error = ErrorCode::MetadataInvalid;
    outcome.detail = inspection.failure_code + L" " + inspection.detail;
    return outcome;
  }
  outcome.identity = inspection.identity;
  if (_wcsicmp(outcome.identity.name.c_str(), metadata.identity_name.c_str()) != 0) {
    outcome.error = ErrorCode::IdentityMismatch;
    outcome.detail = L"identity-name";
    return outcome;
  }
  if (!nh::SamePublisher(outcome.identity.publisher, metadata.publisher)) {
    outcome.error = ErrorCode::PublisherMismatch;
    outcome.detail = L"identity-publisher";
    return outcome;
  }
  if (!nh::SameArchitecture(outcome.identity.architecture,
                            metadata.architecture)) {
    outcome.error = ErrorCode::ArchitectureMismatch;
    outcome.detail = L"identity-architecture";
    return outcome;
  }
  if (!SameVersionText(outcome.identity.VersionString(),
                       metadata.msix_version)) {
    outcome.error = ErrorCode::VersionMismatch;
    outcome.detail = L"identity-version " + outcome.identity.VersionString();
    return outcome;
  }
  const std::wstring derived_family =
      nh::PackageFamilyName(outcome.identity.name, outcome.identity.publisher);
  if (_wcsicmp(derived_family.c_str(), metadata.family_name.c_str()) != 0) {
    outcome.error = ErrorCode::IdentityMismatch;
    outcome.detail = L"family-name " + derived_family;
    return outcome;
  }

  // 签名：先证明密码学完整性，再证明签名者就是内嵌的固定证书。
  const auto signature =
      nh::VerifyPackageSignature(package_path, metadata.publisher);
  outcome.signature = signature;
  if (!signature.present) {
    outcome.error = ErrorCode::SignatureInvalid;
    outcome.detail = L"signature-missing";
    return outcome;
  }
  if (!signature.crypto_valid) {
    outcome.error = ErrorCode::SignatureInvalid;
    outcome.detail = L"signature-crypto-invalid";
    return outcome;
  }
  if (!nh::SameCertificate(signature.signer_certificate, certificate)) {
    outcome.error = ErrorCode::SignatureInvalid;
    outcome.detail = L"signer-not-pinned-certificate " + signature.signer_subject;
    return outcome;
  }
  if (require_trust && !signature.chain_trusted) {
    outcome.error = ErrorCode::CertificateUntrusted;
    outcome.detail = L"chain-untrusted";
    return outcome;
  }

  outcome.ok = true;
  outcome.error = ErrorCode::None;
  return outcome;
}

}  // namespace planner::installer
