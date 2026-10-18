#include "certificate_manager.h"

#include <wincrypt.h>

#include <cstdio>
#include <iterator>
#include <vector>

#include "native_shared/package_deployment.h"
#include "native_shared/package_inspector.h"
#include "native_shared/planner_identity.h"
#include "native_shared/text.h"

namespace planner::installer {
namespace {

namespace nh = planner::native;

std::wstring PropertyHex(PCCERT_CONTEXT context, DWORD property) {
  DWORD size = 0;
  if (!CertGetCertificateContextProperty(context, property, nullptr, &size)) {
    return {};
  }
  std::vector<BYTE> bytes(size);
  if (!CertGetCertificateContextProperty(context, property, bytes.data(),
                                         &size)) {
    return {};
  }
  bytes.resize(size);
  std::wstring hex = nh::HexEncode(bytes);
  for (wchar_t& character : hex) character = towupper(character);
  return hex;
}

std::wstring PublicKeySha256(PCCERT_CONTEXT context) {
  DWORD size = 0;
  if (!CryptEncodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO,
                           &context->pCertInfo->SubjectPublicKeyInfo, 0, nullptr,
                           nullptr, &size)) {
    return {};
  }
  std::vector<BYTE> encoded(size);
  if (!CryptEncodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO,
                           &context->pCertInfo->SubjectPublicKeyInfo, 0, nullptr,
                           encoded.data(), &size)) {
    return {};
  }
  encoded.resize(size);
  std::vector<BYTE> digest;
  if (!nh::Sha256Bytes(encoded.data(), encoded.size(), digest)) return {};
  return nh::HexEncode(digest);
}

HCERTSTORE OpenTrustedPeople(DWORD flags) {
  return CertOpenStore(CERT_STORE_PROV_SYSTEM_W, 0, 0,
                       CERT_SYSTEM_STORE_LOCAL_MACHINE | flags,
                       const_cast<wchar_t*>(L"TrustedPeople"));
}

}  // namespace

bool ParseCertificate(const std::vector<BYTE>& der, CertificateInfo& info,
                      std::wstring& error) {
  info = CertificateInfo{};
  if (der.empty()) {
    error = L"empty";
    return false;
  }
  PCCERT_CONTEXT context =
      CertCreateCertificateContext(X509_ASN_ENCODING, der.data(),
                                   static_cast<DWORD>(der.size()));
  if (context == nullptr) {
    error = L"parse";
    return false;
  }
  info.der = der;
  info.thumbprint = PropertyHex(context, CERT_SHA1_HASH_PROP_ID);
  std::vector<BYTE> digest;
  if (nh::Sha256Bytes(der.data(), der.size(), digest)) {
    info.sha256 = nh::HexEncode(digest);
  }
  info.public_key_sha256 = PublicKeySha256(context);
  wchar_t subject[1024]{};
  if (CertNameToStr(X509_ASN_ENCODING, &context->pCertInfo->Subject,
                    CERT_X500_NAME_STR, subject,
                    static_cast<DWORD>(std::size(subject))) > 1) {
    info.subject = subject;
  }
  info.not_after = context->pCertInfo->NotAfter;
  FILETIME now{};
  GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER expiry{};
  expiry.LowPart = info.not_after.dwLowDateTime;
  expiry.HighPart = info.not_after.dwHighDateTime;
  ULARGE_INTEGER current{};
  current.LowPart = now.dwLowDateTime;
  current.HighPart = now.dwHighDateTime;
  info.expired = expiry.QuadPart <= current.QuadPart;
  CertFreeCertificateContext(context);
  return !info.thumbprint.empty() && !info.sha256.empty();
}

bool IsTrustedForSideloading(const std::vector<BYTE>& der, bool& present,
                             std::wstring& error) {
  present = false;
  PCCERT_CONTEXT context = CertCreateCertificateContext(
      X509_ASN_ENCODING, der.data(), static_cast<DWORD>(der.size()));
  if (context == nullptr) {
    error = L"certificate-parse";
    return false;
  }
  HCERTSTORE store = OpenTrustedPeople(CERT_STORE_READONLY_FLAG |
                                       CERT_STORE_OPEN_EXISTING_FLAG);
  if (store == nullptr) {
    CertFreeCertificateContext(context);
    error = L"store-open";
    return false;
  }
  PCCERT_CONTEXT found =
      CertFindCertificateInStore(store, X509_ASN_ENCODING, 0, CERT_FIND_EXISTING,
                                 context, nullptr);
  present = found != nullptr;
  if (found != nullptr) CertFreeCertificateContext(found);
  CertCloseStore(store, 0);
  CertFreeCertificateContext(context);
  return true;
}

TrustResult TrustCertificate(const std::vector<BYTE>& der) {
  TrustResult result;
  PCCERT_CONTEXT context = CertCreateCertificateContext(
      X509_ASN_ENCODING, der.data(), static_cast<DWORD>(der.size()));
  if (context == nullptr) {
    result.error = L"INSTALLER_CERTIFICATE_PARSE_FAILED";
    return result;
  }
  DWORD size = 0;
  if (CertGetCertificateContextProperty(context, CERT_SHA1_HASH_PROP_ID,
                                        nullptr, &size)) {
    std::vector<BYTE> bytes(size);
    if (CertGetCertificateContextProperty(context, CERT_SHA1_HASH_PROP_ID,
                                          bytes.data(), &size)) {
      bytes.resize(size);
      std::wstring hex = nh::HexEncode(bytes);
      for (wchar_t& character : hex) character = towupper(character);
      result.thumbprint = hex;
    }
  }
  HCERTSTORE store = OpenTrustedPeople(0);
  if (store == nullptr) {
    CertFreeCertificateContext(context);
    result.error = L"INSTALLER_CERTIFICATE_STORE_UNAVAILABLE";
    return result;
  }
  PCCERT_CONTEXT existing =
      CertFindCertificateInStore(store, X509_ASN_ENCODING, 0, CERT_FIND_EXISTING,
                                 context, nullptr);
  if (existing != nullptr) {
    CertFreeCertificateContext(existing);
    result.ok = true;
    result.already_present = true;
  } else if (CertAddCertificateContextToStore(store, context,
                                              CERT_STORE_ADD_USE_EXISTING,
                                              nullptr)) {
    result.ok = true;
  } else {
    wchar_t buffer[64]{};
    swprintf_s(buffer, L"INSTALLER_CERTIFICATE_IMPORT_FAILED_%lu",
               GetLastError());
    result.error = buffer;
  }
  CertCloseStore(store, 0);
  CertFreeCertificateContext(context);
  return result;
}

bool CanSafelyRemoveCertificate(const std::vector<BYTE>& der,
                                bool was_present_before, std::wstring& reason) {
  if (was_present_before) {
    reason = L"certificate-existed-before";
    return false;
  }
  std::wstring error;
  const auto packages =
      nh::FindPackagesForIdentity(nh::kIdentityName, error);
  if (!packages.empty()) {
    reason = L"packages-still-registered";
    return false;
  }
  if (!nh::SamePublisher(nh::CertificateSubject(der), nh::kPublisher)) {
    reason = L"publisher-not-fixed";
    return false;
  }
  reason.clear();
  return true;
}

bool RemoveCertificate(const std::vector<BYTE>& der, std::wstring& error) {
  PCCERT_CONTEXT context = CertCreateCertificateContext(
      X509_ASN_ENCODING, der.data(), static_cast<DWORD>(der.size()));
  if (context == nullptr) {
    error = L"certificate-parse";
    return false;
  }
  HCERTSTORE store = OpenTrustedPeople(0);
  if (store == nullptr) {
    CertFreeCertificateContext(context);
    error = L"store-open";
    return false;
  }
  PCCERT_CONTEXT existing =
      CertFindCertificateInStore(store, X509_ASN_ENCODING, 0, CERT_FIND_EXISTING,
                                 context, nullptr);
  bool ok = false;
  if (existing != nullptr) {
    ok = CertDeleteCertificateFromStore(existing) != FALSE;
    if (!ok) error = L"certificate-delete";
  } else {
    error = L"certificate-not-present";
  }
  CertCloseStore(store, 0);
  CertFreeCertificateContext(context);
  return ok;
}

}  // namespace planner::installer
