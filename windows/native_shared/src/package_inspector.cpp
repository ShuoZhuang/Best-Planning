#include "native_shared/package_inspector.h"

#include <appxpackaging.h>
#include <shlwapi.h>
#include <softpub.h>
#include <winrt/Windows.ApplicationModel.h>
#include <wintrust.h>

#include <algorithm>
#include <cstdio>
#include <map>
#include <regex>
#include <string>
#include <vector>

#include "native_shared/planner_identity.h"
#include "native_shared/text.h"
#include "native_shared/zip_reader.h"

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "wintrust.lib")

namespace planner::native {
namespace {

std::wstring ToUpper(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(towupper(c)); });
  return value;
}

std::wstring Trim(const std::wstring& value) {
  const auto first = value.find_first_not_of(L" \t\r\n");
  if (first == std::wstring::npos) return {};
  const auto last = value.find_last_not_of(L" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::wstring ArchitectureName(APPX_PACKAGE_ARCHITECTURE architecture) {
  switch (architecture) {
    case APPX_PACKAGE_ARCHITECTURE_X86:
      return L"x86";
    case APPX_PACKAGE_ARCHITECTURE_ARM:
      return L"arm";
    case APPX_PACKAGE_ARCHITECTURE_X64:
      return L"x64";
    case APPX_PACKAGE_ARCHITECTURE_NEUTRAL:
      return L"neutral";
    case APPX_PACKAGE_ARCHITECTURE_ARM64:
      return L"arm64";
    default:
      return L"unknown";
  }
}

bool ReadStream(IStream* stream, std::vector<BYTE>& bytes) {
  if (stream == nullptr) return false;
  STATSTG stat{};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME))) return false;
  LARGE_INTEGER zero{};
  stream->Seek(zero, STREAM_SEEK_SET, nullptr);
  bytes.resize(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG read = 0;
  size_t offset = 0;
  while (offset < bytes.size()) {
    const ULONG chunk = static_cast<ULONG>(
        std::min<size_t>(bytes.size() - offset, 1 << 20));
    if (FAILED(stream->Read(bytes.data() + offset, chunk, &read)) || read == 0) {
      return false;
    }
    offset += read;
  }
  return true;
}

std::wstring OidShortName(const std::wstring& oid) {
  if (oid == L"2.5.4.3") return L"CN";
  if (oid == L"2.5.4.4") return L"SN";
  if (oid == L"2.5.4.5") return L"SERIALNUMBER";
  if (oid == L"2.5.4.6") return L"C";
  if (oid == L"2.5.4.7") return L"L";
  if (oid == L"2.5.4.8") return L"S";
  if (oid == L"2.5.4.9") return L"STREET";
  if (oid == L"2.5.4.10") return L"O";
  if (oid == L"2.5.4.11") return L"OU";
  if (oid == L"2.5.4.12") return L"T";
  if (oid == L"1.2.840.113549.1.9.1") return L"E";
  return oid;
}

std::wstring RdnValue(const CERT_RDN_ATTR& attribute) {
  const BYTE* data = attribute.Value.pbData;
  const DWORD size = attribute.Value.cbData;
  switch (attribute.dwValueType) {
    case CERT_RDN_BMP_STRING:
      return std::wstring(reinterpret_cast<const wchar_t*>(data),
                          size / sizeof(wchar_t));
    case CERT_RDN_UTF8_STRING:
      return WideFromUtf8(
          std::string(reinterpret_cast<const char*>(data), size));
    case CERT_RDN_IA5_STRING:
    case CERT_RDN_PRINTABLE_STRING:
    case CERT_RDN_T61_STRING:
    case CERT_RDN_NUMERIC_STRING:
    case CERT_RDN_VISIBLE_STRING:
      // 单字节字符：逐字节提升为宽字符，不能按 wchar_t 读取（会越界一倍）。
      return std::wstring(data, data + size);
    default:
      return WideFromUtf8(
          std::string(reinterpret_cast<const char*>(data), size));
  }
}

std::map<std::wstring, std::wstring> SubjectAttributes(PCCERT_CONTEXT cert) {
  std::map<std::wstring, std::wstring> attributes;
  CERT_NAME_INFO* name = nullptr;
  DWORD size = 0;
  if (!CryptDecodeObjectEx(X509_ASN_ENCODING, X509_NAME,
                           cert->pCertInfo->Subject.pbData,
                           cert->pCertInfo->Subject.cbData,
                           CRYPT_DECODE_ALLOC_FLAG, nullptr, &name, &size)) {
    return attributes;
  }
  for (DWORD i = 0; i < name->cRDN; ++i) {
    for (DWORD j = 0; j < name->rgRDN[i].cRDNAttr; ++j) {
      const auto& attribute = name->rgRDN[i].rgRDNAttr[j];
      attributes[ToUpper(OidShortName(WideFromUtf8(attribute.pszObjId)))] =
          RdnValue(attribute);
    }
  }
  LocalFree(name);
  return attributes;
}

std::map<std::wstring, std::wstring> ParseDistinguishedName(
    const std::wstring& value) {
  std::map<std::wstring, std::wstring> attributes;
  size_t start = 0;
  while (start <= value.size()) {
    const size_t comma = value.find(L',', start);
    const std::wstring part = Trim(value.substr(
        start, comma == std::wstring::npos ? std::wstring::npos
                                           : comma - start));
    if (!part.empty()) {
      const size_t equals = part.find(L'=');
      if (equals != std::wstring::npos) {
        attributes[ToUpper(Trim(part.substr(0, equals)))] = Trim(
            part.substr(equals + 1));
      }
    }
    if (comma == std::wstring::npos) break;
    start = comma + 1;
  }
  return attributes;
}

bool PublisherMatches(PCCERT_CONTEXT cert, const std::wstring& publisher) {
  const auto expected = ParseDistinguishedName(publisher);
  if (expected.empty()) return false;
  wchar_t x500[2048]{};
  if (CertNameToStr(X509_ASN_ENCODING, &cert->pCertInfo->Subject,
                    CERT_X500_NAME_STR, x500,
                    static_cast<DWORD>(std::size(x500))) > 1) {
    const auto actual = ParseDistinguishedName(x500);
    bool matches = true;
    for (const auto& [key, value] : expected) {
      const auto found = actual.find(key);
      if (found == actual.end() ||
          _wcsicmp(Trim(found->second).c_str(), value.c_str()) != 0) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  const auto actual = SubjectAttributes(cert);
  for (const auto& [key, value] : expected) {
    const auto found = actual.find(key);
    if (found == actual.end() ||
        _wcsicmp(Trim(found->second).c_str(), value.c_str()) != 0) {
      return false;
    }
  }
  return true;
}

bool ChainTrusted(PCCERT_CONTEXT cert) {
  PCCERT_CHAIN_CONTEXT chain = nullptr;
  CERT_CHAIN_PARA chain_para{};
  chain_para.cbSize = sizeof(chain_para);
  if (!CertGetCertificateChain(nullptr, cert, nullptr, cert->hCertStore,
                               &chain_para, 0, nullptr, &chain)) {
    return false;
  }
  CERT_CHAIN_POLICY_PARA policy_para{};
  policy_para.cbSize = sizeof(policy_para);
  CERT_CHAIN_POLICY_STATUS policy_status{};
  policy_status.cbSize = sizeof(policy_status);
  const bool ok =
      CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_BASE, chain,
                                       &policy_para, &policy_status) != FALSE &&
      policy_status.dwError == 0;
  CertFreeCertificateChain(chain);
  return ok;
}

struct WinTrustOutcome {
  bool has_signature = false;
  bool crypto_ok = false;
  bool trusted = false;
  HRESULT status = E_UNEXPECTED;
  PCCERT_CONTEXT signer = nullptr;

  ~WinTrustOutcome() {
    if (signer != nullptr) CertFreeCertificateContext(signer);
  }
};

// 用 Windows 的 Appx SIP 校验整个包：同时给出"密码学有效"与"链是否受信任"两类信息。
// 离线场景强制 `WTD_CACHE_ONLY_URL_RETRIEVAL`，不做任何联网的吊销或时间戳查询。
WinTrustOutcome VerifyWithWindowsTrust(const std::wstring& path) {
  WinTrustOutcome outcome;
  WINTRUST_FILE_INFO file_info{};
  file_info.cbStruct = sizeof(file_info);
  file_info.pcwszFilePath = path.c_str();

  WINTRUST_DATA data{};
  data.cbStruct = sizeof(data);
  data.dwUIChoice = WTD_UI_NONE;
  data.fdwRevocationChecks = WTD_REVOKE_NONE;
  data.dwUnionChoice = WTD_CHOICE_FILE;
  data.pFile = &file_info;
  data.dwStateAction = WTD_STATEACTION_VERIFY;
  data.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL | WTD_REVOCATION_CHECK_NONE;

  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  outcome.status = static_cast<HRESULT>(WinVerifyTrust(nullptr, &action, &data));
  outcome.has_signature = outcome.status != TRUST_E_NOSIGNATURE &&
                          outcome.status != TRUST_E_SUBJECT_FORM_UNKNOWN &&
                          outcome.status != TRUST_E_PROVIDER_UNKNOWN;
  outcome.trusted = outcome.status == ERROR_SUCCESS;
  outcome.crypto_ok = outcome.trusted ||
                      outcome.status == CERT_E_UNTRUSTEDROOT ||
                      outcome.status == CERT_E_CHAINING ||
                      outcome.status == TRUST_E_EXPLICIT_DISTRUST;

  if (data.hWVTStateData != nullptr) {
    CRYPT_PROVIDER_DATA* provider =
        WTHelperProvDataFromStateData(data.hWVTStateData);
    if (provider != nullptr) {
      CRYPT_PROVIDER_SGNR* signer =
          WTHelperGetProvSignerFromChain(provider, 0, FALSE, 0);
      if (signer != nullptr && signer->csCertChain > 0 &&
          signer->pasCertChain != nullptr) {
        outcome.signer =
            CertDuplicateCertificateContext(signer->pasCertChain[0].pCert);
      }
    }
  }

  data.dwStateAction = WTD_STATEACTION_CLOSE;
  WinVerifyTrust(nullptr, &action, &data);
  return outcome;
}

IStream* OpenPackageStream(const std::wstring& path) {
  IStream* stream = nullptr;
  if (FAILED(SHCreateStreamOnFileEx(path.c_str(),
                                    STGM_READ | STGM_SHARE_DENY_NONE,
                                    FILE_ATTRIBUTE_NORMAL, FALSE, nullptr,
                                    &stream))) {
    return nullptr;
  }
  return stream;
}

// AppxPackaging 不可用时的降级路径：直接读 ZIP 里的 AppxManifest.xml。
bool ReadIdentityFromZip(const std::wstring& path, PackageIdentity& identity,
                         std::wstring& detail) {
  std::vector<BYTE> manifest;
  if (!ReadZipEntry(path, "AppxManifest.xml", manifest) || manifest.empty()) {
    detail = L"zip-entry-failed";
    return false;
  }
  const std::string utf8(manifest.begin(), manifest.end());
  const std::wstring xml = WideFromUtf8(utf8);
  const auto start = xml.find(L"<Identity");
  if (start == std::wstring::npos) {
    detail = L"identity-tag-missing";
    return false;
  }
  const auto end = xml.find(L'>', start);
  if (end == std::wstring::npos) {
    detail = L"identity-tag-missing";
    return false;
  }
  const std::wstring tag = xml.substr(start, end - start);
  auto attribute = [&tag](const wchar_t* name) -> std::wstring {
    const std::wregex pattern(L"\\b" + std::wstring(name) +
                              L"\\s*=\\s*\"([^\"]*)\"");
    std::wsmatch match;
    if (!std::regex_search(tag, match, pattern)) return {};
    return match[1].str();
  };
  const std::wstring name = attribute(L"Name");
  const std::wstring publisher = attribute(L"Publisher");
  const std::wstring version_text = attribute(L"Version");
  const std::wstring architecture = attribute(L"ProcessorArchitecture");
  if (name.empty() || publisher.empty() || version_text.empty()) {
    detail = L"identity-attribute-missing";
    return false;
  }
  PackageVersion version;
  if (!PackageVersion::Parse(version_text, version)) {
    detail = L"identity-version-invalid";
    return false;
  }
  identity.name = name;
  identity.publisher = publisher;
  identity.version = version.Encode();
  identity.architecture = architecture.empty() ? L"neutral" : architecture;
  identity.family_name = PackageFamilyName(name, publisher);
  identity.packaged = true;
  return true;
}

InspectionResult ReadIdentity(const std::wstring& path) {
  InspectionResult result;
  IAppxFactory* factory = nullptr;
  IStream* stream = nullptr;
  IAppxPackageReader* reader = nullptr;
  IAppxManifestReader* manifest = nullptr;
  IAppxManifestPackageId* package_id = nullptr;

  auto fail_with = [&result](const wchar_t* stage, HRESULT hr) {
    result.failure_code = L"UPDATE_PACKAGE_FORMAT_INVALID";
    wchar_t buffer[80]{};
    swprintf_s(buffer, L"%s hresult=0x%08X", stage,
               static_cast<unsigned int>(hr));
    result.detail = buffer;
  };

  do {
    HRESULT hr = CoCreateInstance(__uuidof(AppxFactory), nullptr,
                                  CLSCTX_INPROC_SERVER, __uuidof(IAppxFactory),
                                  reinterpret_cast<void**>(&factory));
    if (FAILED(hr)) {
      fail_with(L"factory", hr);
      break;
    }
    stream = OpenPackageStream(path);
    if (stream == nullptr) {
      fail_with(L"open", E_FAIL);
      break;
    }
    hr = factory->CreatePackageReader(stream, &reader);
    if (FAILED(hr)) {
      fail_with(L"reader", hr);
      break;
    }
    hr = reader->GetManifest(&manifest);
    if (FAILED(hr)) {
      fail_with(L"manifest", hr);
      break;
    }
    hr = manifest->GetPackageId(&package_id);
    if (FAILED(hr)) {
      fail_with(L"packageid", hr);
      break;
    }
    LPWSTR value = nullptr;
    if (SUCCEEDED(package_id->GetName(&value))) {
      result.identity.name = value;
      CoTaskMemFree(value);
      value = nullptr;
    }
    if (SUCCEEDED(package_id->GetPublisher(&value))) {
      result.identity.publisher = value;
      CoTaskMemFree(value);
      value = nullptr;
    }
    UINT64 version = 0;
    package_id->GetVersion(&version);
    result.identity.version = version;
    APPX_PACKAGE_ARCHITECTURE architecture = APPX_PACKAGE_ARCHITECTURE_NEUTRAL;
    package_id->GetArchitecture(&architecture);
    result.identity.architecture = ArchitectureName(architecture);
    result.identity.family_name =
        PackageFamilyName(result.identity.name, result.identity.publisher);
    result.identity.packaged = true;
    result.ok = true;
  } while (false);

  if (package_id != nullptr) package_id->Release();
  if (manifest != nullptr) manifest->Release();
  if (reader != nullptr) reader->Release();
  if (stream != nullptr) stream->Release();
  if (factory != nullptr) factory->Release();
  if (!result.ok) {
    // AppxPackaging 在受限令牌下会返回 E_ACCESSDENIED；直接读 ZIP 清单作为降级路径。
    PackageIdentity fallback;
    std::wstring fallback_detail;
    if (ReadIdentityFromZip(path, fallback, fallback_detail)) {
      result.ok = true;
      result.failure_code.clear();
      result.detail.clear();
      result.identity = fallback;
    } else {
      result.detail += L" ";
      result.detail += fallback_detail;
    }
  }
  return result;
}

bool ReadSignatureBlob(const std::wstring& path, std::vector<BYTE>& blob,
                       std::wstring& detail) {
  if (!ReadZipEntry(path, "AppxSignature.p7x", blob) || blob.empty()) {
    detail = L"signature-entry-missing";
    return false;
  }
  // AppxSignature.p7x 以 4 字节 `PKCX` 头开始，后面才是 PKCS#7 SignedData。
  if (blob.size() > 4 && blob[0] == 'P' && blob[1] == 'K' && blob[2] == 'C' &&
      blob[3] == 'X') {
    blob.erase(blob.begin(), blob.begin() + 4);
  }
  return !blob.empty();
}

}  // namespace

std::wstring PackageIdentity::VersionString() const {
  return Version().ToString();
}

std::wstring CertificateSubject(const std::vector<BYTE>& certificate) {
  if (certificate.empty()) return {};
  PCCERT_CONTEXT context =
      CertCreateCertificateContext(X509_ASN_ENCODING, certificate.data(),
                                   static_cast<DWORD>(certificate.size()));
  if (context == nullptr) return {};
  wchar_t buffer[1024]{};
  std::wstring subject;
  if (CertNameToStr(X509_ASN_ENCODING, &context->pCertInfo->Subject,
                    CERT_X500_NAME_STR, buffer,
                    static_cast<DWORD>(std::size(buffer))) > 1) {
    subject = buffer;
  }
  CertFreeCertificateContext(context);
  return subject;
}

bool SameCertificate(const std::vector<BYTE>& left,
                     const std::vector<BYTE>& right) {
  return !left.empty() && !right.empty() && left.size() == right.size() &&
         memcmp(left.data(), right.data(), left.size()) == 0;
}

PackageSignature VerifyPackageSignature(const std::wstring& path,
                                        const std::wstring& expected_publisher) {
  PackageSignature signature;
  std::vector<BYTE> blob;
  if (!ReadSignatureBlob(path, blob, signature.detail)) {
    signature.failure_code = L"UPDATE_PACKAGE_SIGNATURE_MISSING";
    return signature;
  }
  signature.present = true;

  PCCERT_CONTEXT signer = nullptr;
  CRYPT_VERIFY_MESSAGE_PARA verify_para{};
  verify_para.cbSize = sizeof(verify_para);
  verify_para.dwMsgAndCertEncodingType = X509_ASN_ENCODING | PKCS_7_ASN_ENCODING;
  if (CryptVerifyMessageSignature(&verify_para, 0, blob.data(),
                                  static_cast<DWORD>(blob.size()), nullptr,
                                  nullptr, &signer) != FALSE &&
      signer != nullptr) {
    // 只验证了 PKCS#7 的内容摘要与签名；证书链信任单独判断（首次安装时尚未信任）。
    signature.crypto_valid = true;
  }

  const WinTrustOutcome trust = VerifyWithWindowsTrust(path);
  if (signer == nullptr && trust.signer != nullptr) {
    signer = CertDuplicateCertificateContext(trust.signer);
  }
  if (!signature.crypto_valid && trust.has_signature && trust.crypto_ok) {
    // PKCS#7 是分离签名时，用 Windows 的 SIP 结果兜底：只有"仅链不受信任"的失败
    // 才视为密码学有效。
    signature.crypto_valid = true;
  }
  signature.chain_trusted = trust.trusted;

  if (signer == nullptr) {
    signature.failure_code = signature.crypto_valid
                                 ? L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED"
                                 : L"UPDATE_PACKAGE_SIGNATURE_INVALID";
    wchar_t buffer[64]{};
    swprintf_s(buffer, L"trust=0x%08X",
               static_cast<unsigned int>(trust.status));
    signature.detail = buffer;
    return signature;
  }

  signature.signer_certificate.assign(
      signer->pbCertEncoded, signer->pbCertEncoded + signer->cbCertEncoded);
  wchar_t subject[1024]{};
  if (CertNameToStr(X509_ASN_ENCODING, &signer->pCertInfo->Subject,
                    CERT_X500_NAME_STR, subject,
                    static_cast<DWORD>(std::size(subject))) > 1) {
    signature.signer_subject = subject;
  }
  // 链信任独立复核：Windows 的 SIP 可能因升级/吊销策略差异给出不同结论，
  // 这里以 CryptoAPI 的 BASE 链策略为准，避免把"包内容被改"误判成"证书尚未信任"。
  signature.chain_trusted = ChainTrusted(signer);
  signature.publisher_matches =
      expected_publisher.empty() || PublisherMatches(signer, expected_publisher);

  if (!signature.crypto_valid) {
    signature.failure_code = L"UPDATE_PACKAGE_SIGNATURE_INVALID";
  } else if (!signature.chain_trusted) {
    signature.failure_code = L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED";
  } else if (!signature.publisher_matches) {
    signature.failure_code = L"UPDATE_PACKAGE_PUBLISHER_MISMATCH";
  }

  CertFreeCertificateContext(signer);
  return signature;
}

InspectionResult InspectPackage(const std::wstring& path, SignatureCheck check,
                                const std::wstring& expected_publisher) {
  InspectionResult result = ReadIdentity(path);
  if (!result.ok) return result;
  if (check == SignatureCheck::None) return result;

  result.signature = VerifyPackageSignature(path, expected_publisher);
  if (!result.signature.present) {
    result.ok = false;
    result.failure_code = L"UPDATE_PACKAGE_SIGNATURE_MISSING";
    return result;
  }
  if (!result.signature.crypto_valid) {
    result.ok = false;
    result.failure_code = L"UPDATE_PACKAGE_SIGNATURE_INVALID";
    result.detail = result.signature.detail;
    return result;
  }
  if (check == SignatureCheck::TrustedChain) {
    if (!result.signature.chain_trusted) {
      result.ok = false;
      result.failure_code = L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED";
      return result;
    }
    if (!result.signature.publisher_matches) {
      result.ok = false;
      result.failure_code = L"UPDATE_PACKAGE_PUBLISHER_MISMATCH";
      return result;
    }
  }
  result.ok = true;
  return result;
}

bool CurrentPackageIdentity(PackageIdentity& out) {
  try {
    const auto package = winrt::Windows::ApplicationModel::Package::Current();
    const auto id = package.Id();
    out.name = id.Name().c_str();
    out.publisher = id.Publisher().c_str();
    out.family_name = id.FamilyName().c_str();
    const auto version = id.Version();
    out.version = (static_cast<std::uint64_t>(version.Major) << 48) |
                  (static_cast<std::uint64_t>(version.Minor) << 32) |
                  (static_cast<std::uint64_t>(version.Build) << 16) |
                  static_cast<std::uint64_t>(version.Revision);
    switch (id.Architecture()) {
      case winrt::Windows::System::ProcessorArchitecture::X86:
        out.architecture = L"x86";
        break;
      case winrt::Windows::System::ProcessorArchitecture::Arm:
        out.architecture = L"arm";
        break;
      case winrt::Windows::System::ProcessorArchitecture::X64:
        out.architecture = L"x64";
        break;
      case winrt::Windows::System::ProcessorArchitecture::Arm64:
        out.architecture = L"arm64";
        break;
      default:
        out.architecture = L"neutral";
        break;
    }
    out.packaged = true;
    return true;
  } catch (...) {
    return false;
  }
}

}  // namespace planner::native
