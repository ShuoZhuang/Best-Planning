#include "package_inspector.h"

#include <bcrypt.h>
#include <shlwapi.h>
#include <winrt/Windows.ApplicationModel.h>

#include <algorithm>
#include <cstdio>
#include <map>
#include <regex>
#include <string>
#include <vector>

#include "zip_reader.h"

#pragma comment(lib, "bcrypt.lib")

namespace update_helper {
namespace {

std::wstring WideFromUtf8(const char* value) {
  if (value == nullptr) return {};
  const int length = MultiByteToWideChar(CP_UTF8, 0, value, -1, nullptr, 0);
  std::wstring result(length > 0 ? length - 1 : 0, L'\0');
  if (length > 1) {
    MultiByteToWideChar(CP_UTF8, 0, value, -1, result.data(), length);
  }
  return result;
}

std::string Utf8FromWide(const std::wstring& value) {
  const int length = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                         0, nullptr, nullptr);
  std::string result(length > 0 ? length - 1 : 0, '\0');
  if (length > 1) {
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), length,
                        nullptr, nullptr);
  }
  return result;
}

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
      return WideFromUtf8(std::string(reinterpret_cast<const char*>(data),
                                      size)
                              .c_str());
    case CERT_RDN_IA5_STRING:
    case CERT_RDN_PRINTABLE_STRING:
    case CERT_RDN_T61_STRING:
    case CERT_RDN_NUMERIC_STRING:
    case CERT_RDN_VISIBLE_STRING:
      // 单字节字符：逐字节提升为宽字符，不能按 wchar_t 读取（会越界一倍）。
      return std::wstring(data, data + size);
    default:
      return WideFromUtf8(std::string(reinterpret_cast<const char*>(data),
                                      size)
                              .c_str());
  }
}

// Windows 的 PublisherId：Publisher 的 UTF-16LE 字节做 SHA-256，取前 8 字节，
// 按 Crockford base32 编码成 13 个字符。与 Dart 侧 `publisherIdFor` 同一实现。
std::wstring PublisherId(const std::wstring& publisher) {
  static const wchar_t* kAlphabet = L"0123456789abcdefghjkmnpqrstvwxyz";
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  BYTE digest[32]{};
  bool ok = false;
  do {
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr,
                                    0) < 0) {
      break;
    }
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
      break;
    }
    // std::wstring 在 Windows 上就是 UTF-16 码元，直接取字节即 UTF-16LE。
    const BYTE* bytes = reinterpret_cast<const BYTE*>(publisher.data());
    const ULONG byte_count =
        static_cast<ULONG>(publisher.size() * sizeof(wchar_t));
    if (BCryptHashData(hash, const_cast<BYTE*>(bytes), byte_count, 0) < 0) {
      break;
    }
    if (BCryptFinishHash(hash, digest, sizeof(digest), 0) < 0) break;
    ok = true;
  } while (false);
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  if (!ok) return L"0000000000000";

  std::wstring result;
  result.reserve(13);
  std::uint64_t value = 0;
  for (int i = 0; i < 8; ++i) {
    value = (value << 8) | digest[i];
  }
  // 64 位摘要按 5 位一组编码成 13 个字符（最后一组只有 4 位，补 0）。
  for (int index = 0; index < 13; ++index) {
    const int consumed = (index + 1) * 5;
    const std::uint64_t chunk =
        consumed <= 64 ? (value >> (64 - consumed)) & 0x1F
                       : (value << (consumed - 64)) & 0x1F;
    result.push_back(kAlphabet[chunk]);
  }
  return result;
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
        attributes[ToUpper(Trim(part.substr(0, equals)))] =
            Trim(part.substr(equals + 1));
      }
    }
    if (comma == std::wstring::npos) break;
    start = comma + 1;
  }
  return attributes;
}

bool PublisherMatches(PCCERT_CONTEXT cert, const std::wstring& publisher) {
  const auto expected = ParseDistinguishedName(publisher);
  wchar_t x500[2048]{};
  if (CertNameToStr(X509_ASN_ENCODING, &cert->pCertInfo->Subject,
                    CERT_X500_NAME_STR, x500,
                    static_cast<DWORD>(std::size(x500))) > 1) {
    const auto actual = ParseDistinguishedName(x500);
    bool matches = !expected.empty();
    for (const auto& [key, value] : expected) {
      const auto found = actual.find(key);
      if (found == actual.end() || found->second != value) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  const auto actual = SubjectAttributes(cert);
  // 期望值形如 `CN=Shuo Zhuang, O=Personal User, C=CN`。逐段比较，顺序无关。
  size_t start = 0;
  while (start <= publisher.size()) {
    const size_t comma = publisher.find(L',', start);
    const std::wstring part = Trim(publisher.substr(
        start, comma == std::wstring::npos ? std::wstring::npos
                                           : comma - start));
    if (!part.empty()) {
      const size_t equals = part.find(L'=');
      if (equals == std::wstring::npos) return false;
      const std::wstring key = ToUpper(Trim(part.substr(0, equals)));
      const std::wstring value = Trim(part.substr(equals + 1));
      const auto found = actual.find(key);
      if (found == actual.end() || Trim(found->second) != value) {
        return false;
      }
    }
    if (comma == std::wstring::npos) break;
    start = comma + 1;
  }
  return true;
}

PCCERT_CONTEXT FindSignerCertificate(CMSG_SIGNER_INFO* signer) {
  CERT_INFO info{};
  info.Issuer = signer->Issuer;
  info.SerialNumber = signer->SerialNumber;
  const wchar_t* stores[] = {L"TrustedPeople", L"Root", L"CA"};
  for (const wchar_t* store_name : stores) {
    HCERTSTORE store = CertOpenStore(
        CERT_STORE_PROV_SYSTEM_W, 0, 0,
        CERT_SYSTEM_STORE_CURRENT_USER | CERT_STORE_READONLY_FLAG |
            CERT_STORE_OPEN_EXISTING_FLAG,
        const_cast<wchar_t*>(store_name));
    if (store == nullptr) continue;
    PCCERT_CONTEXT cert = CertFindCertificateInStore(
        store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, 0,
        CERT_FIND_SUBJECT_CERT, &info, nullptr);
    if (cert != nullptr) cert = CertDuplicateCertificateContext(cert);
    CertCloseStore(store, 0);
    if (cert != nullptr) return cert;
  }
  return nullptr;
}

// 验证 AppxSignature.p7x：PKCS#7 签名、证书链与发布者。
std::wstring VerifySignature(const std::vector<BYTE>& signature_blob,
                             const std::wstring& expected_publisher) {
  if (signature_blob.empty()) return L"UPDATE_PACKAGE_SIGNATURE_MISSING";
  CRYPT_VERIFY_MESSAGE_PARA verify_para{};
  verify_para.cbSize = sizeof(verify_para);
  verify_para.dwMsgAndCertEncodingType =
      X509_ASN_ENCODING | PKCS_7_ASN_ENCODING;
  PCCERT_CONTEXT cert = nullptr;
  if (!CryptVerifyMessageSignature(&verify_para, 0, signature_blob.data(),
                                   static_cast<DWORD>(signature_blob.size()),
                                   nullptr, nullptr, &cert) ||
      cert == nullptr) {
    if (cert != nullptr) CertFreeCertificateContext(cert);
    return L"UPDATE_PACKAGE_SIGNATURE_INVALID";
  }

  std::wstring failure;
  PCCERT_CHAIN_CONTEXT chain = nullptr;
  CERT_CHAIN_PARA chain_para{};
  chain_para.cbSize = sizeof(chain_para);
  if (!CertGetCertificateChain(nullptr, cert, nullptr, cert->hCertStore,
                               &chain_para, 0, nullptr, &chain)) {
    failure = L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED";
  } else {
    CERT_CHAIN_POLICY_PARA policy_para{};
    policy_para.cbSize = sizeof(policy_para);
    CERT_CHAIN_POLICY_STATUS policy_status{};
    policy_status.cbSize = sizeof(policy_status);
    if (!CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_BASE, chain,
                                          &policy_para, &policy_status) ||
        policy_status.dwError != 0) {
      failure = L"UPDATE_PACKAGE_CERTIFICATE_UNTRUSTED";
    } else if (!PublisherMatches(cert, expected_publisher)) {
      failure = L"UPDATE_PACKAGE_PUBLISHER_MISMATCH";
    }
  }
  if (chain != nullptr) CertFreeCertificateChain(chain);
  CertFreeCertificateContext(cert);
  return failure;
}

IStream* OpenPackageStream(const std::wstring& path) {
  IStream* stream = nullptr;
  if (FAILED(SHCreateStreamOnFileEx(path.c_str(), STGM_READ | STGM_SHARE_DENY_NONE,
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
  const std::wstring xml = WideFromUtf8(utf8.c_str());
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
  unsigned major = 0, minor = 0, build = 0, revision = 0;
  if (swscanf_s(version_text.c_str(), L"%u.%u.%u.%u", &major, &minor, &build,
                &revision) != 4) {
    detail = L"identity-version-invalid";
    return false;
  }
  identity.name = name;
  identity.publisher = publisher;
  identity.version = (static_cast<std::uint64_t>(major) << 48) |
                     (static_cast<std::uint64_t>(minor) << 32) |
                     (static_cast<std::uint64_t>(build) << 16) |
                     static_cast<std::uint64_t>(revision);
  identity.architecture = architecture.empty() ? L"neutral" : architecture;
  identity.family_name = name + L"_" + PublisherId(publisher);
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
  IAppxFile* signature_file = nullptr;
  IStream* signature_stream = nullptr;

  do {
    HRESULT hr = CoCreateInstance(__uuidof(AppxFactory), nullptr,
                                  CLSCTX_INPROC_SERVER,
                                  __uuidof(IAppxFactory),
                                  reinterpret_cast<void**>(&factory));
    if (FAILED(hr)) {
      result.failure_code = L"UPDATE_PACKAGE_FORMAT_INVALID";
      wchar_t buffer[32]{};
      swprintf_s(buffer, L"%s hresult=0x%08X", L"factory", static_cast<unsigned int>(hr));
      result.detail = buffer;
      break;
    }
    stream = OpenPackageStream(path);
    if (stream == nullptr) {
      result.failure_code = L"UPDATE_PACKAGE_FORMAT_INVALID";
      wchar_t buffer[32]{};
      swprintf_s(buffer, L"%s hresult=0x%08X", L"open", static_cast<unsigned int>(hr));
      result.detail = buffer;
      break;
    }
    hr = factory->CreatePackageReader(stream, &reader);
    if (FAILED(hr)) {
      result.failure_code = L"UPDATE_PACKAGE_FORMAT_INVALID";
      wchar_t buffer[32]{};
      swprintf_s(buffer, L"%s hresult=0x%08X", L"reader", static_cast<unsigned int>(hr));
      result.detail = buffer;
      break;
    }
    hr = reader->GetManifest(&manifest);
    if (FAILED(hr)) {
      result.failure_code = L"UPDATE_PACKAGE_FORMAT_INVALID";
      wchar_t buffer[32]{};
      swprintf_s(buffer, L"%s hresult=0x%08X", L"manifest", static_cast<unsigned int>(hr));
      result.detail = buffer;
      break;
    }
    hr = manifest->GetPackageId(&package_id);
    if (FAILED(hr)) {
      result.failure_code = L"UPDATE_PACKAGE_FORMAT_INVALID";
      wchar_t buffer[32]{};
      swprintf_s(buffer, L"%s hresult=0x%08X", L"packageid", static_cast<unsigned int>(hr));
      result.detail = buffer;
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
    result.identity.family_name = result.identity.name + L"_" +
                                  PublisherId(result.identity.publisher);
    result.identity.packaged = true;
    result.ok = true;
  } while (false);

  if (package_id != nullptr) package_id->Release();
  if (manifest != nullptr) manifest->Release();
  if (reader != nullptr) reader->Release();
  if (signature_stream != nullptr) signature_stream->Release();
  if (signature_file != nullptr) signature_file->Release();
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

}  // namespace

std::wstring PackageIdentity::VersionString() const {
  wchar_t buffer[32]{};
  swprintf_s(buffer, L"%llu.%llu.%llu.%llu",
             (version >> 48) & 0xFFFF, (version >> 32) & 0xFFFF,
             (version >> 16) & 0xFFFF, version & 0xFFFF);
  return buffer;
}

InspectionResult InspectPackage(const std::wstring& path,
                                bool verify_signature) {
  InspectionResult result = ReadIdentity(path);
  if (!result.ok) return result;

  // 签名文件直接从 ZIP 读：`AppxSignature.p7x` 是 stored 条目，不依赖 AppxPackaging。
  std::vector<BYTE> signature_blob;
  if (!ReadZipEntry(path, "AppxSignature.p7x", signature_blob) ||
      signature_blob.empty()) {
    result.ok = false;
    result.failure_code = L"UPDATE_PACKAGE_SIGNATURE_MISSING";
    return result;
  }
  // AppxSignature.p7x 以 4 字节 `PKCX` 头开始，后面才是 PKCS#7 SignedData。
  if (signature_blob.size() > 4 && signature_blob[0] == 'P' &&
      signature_blob[1] == 'K' && signature_blob[2] == 'C' &&
      signature_blob[3] == 'X') {
    signature_blob.erase(signature_blob.begin(), signature_blob.begin() + 4);
  }

  if (verify_signature) {
    const std::wstring failure = VerifySignature(signature_blob,
                                                 result.identity.publisher);
    if (!failure.empty()) {
      result.ok = false;
      result.failure_code = failure;
    }
  }
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

bool Sha256File(const std::wstring& path, std::vector<BYTE>& digest) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  bool ok = false;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  do {
    if (file == INVALID_HANDLE_VALUE) break;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                    nullptr, 0) < 0) {
      break;
    }
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) < 0) {
      break;
    }
    std::vector<BYTE> buffer(1 << 20);
    DWORD read = 0;
    bool read_failed = false;
    while (ReadFile(file, buffer.data(), static_cast<DWORD>(buffer.size()),
                    &read, nullptr) &&
           read > 0) {
      if (BCryptHashData(hash, buffer.data(), read, 0) < 0) {
        read_failed = true;
        break;
      }
    }
    if (read_failed) break;
    digest.resize(32);
    if (BCryptFinishHash(hash, digest.data(),
                         static_cast<ULONG>(digest.size()), 0) < 0) {
      break;
    }
    ok = true;
  } while (false);
  if (hash != nullptr) BCryptDestroyHash(hash);
  if (algorithm != nullptr) BCryptCloseAlgorithmProvider(algorithm, 0);
  if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
  return ok;
}

bool IsPathUnderRoot(const std::wstring& path, const std::wstring& root) {
  wchar_t full_path[MAX_PATH * 2]{};
  wchar_t full_root[MAX_PATH * 2]{};
  if (GetFullPathNameW(path.c_str(), MAX_PATH * 2, full_path, nullptr) == 0) {
    return false;
  }
  if (GetFullPathNameW(root.c_str(), MAX_PATH * 2, full_root, nullptr) == 0) {
    return false;
  }
  std::wstring candidate(full_path);
  std::wstring base(full_root);
  while (!base.empty() && (base.back() == L'\\' || base.back() == L'/')) {
    base.pop_back();
  }
  if (candidate.size() <= base.size() + 1) return false;
  if (_wcsnicmp(candidate.c_str(), base.c_str(), base.size()) != 0) {
    return false;
  }
  return candidate[base.size()] == L'\\' || candidate[base.size()] == L'/';
}

}  // namespace update_helper



