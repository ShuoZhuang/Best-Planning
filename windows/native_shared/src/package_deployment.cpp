#include "native_shared/package_deployment.h"

#include <appmodel.h>
#include <shobjidl_core.h>
#include <tlhelp32.h>

#include <winrt/Windows.ApplicationModel.Core.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Management.Deployment.h>

#include <algorithm>
#include <cstdio>

#include "native_shared/planner_identity.h"
#include "native_shared/text.h"

using winrt::Windows::ApplicationModel::Package;
using winrt::Windows::ApplicationModel::PackageStatus;
using winrt::Windows::Foundation::Uri;
using winrt::Windows::Management::Deployment::DeploymentOptions;
using winrt::Windows::Management::Deployment::DeploymentResult;
using winrt::Windows::Management::Deployment::PackageManager;

namespace planner::native {
namespace {

std::wstring FileUri(const std::wstring& path) {
  std::wstring uri = L"file:///";
  for (wchar_t character : path) {
    uri.push_back(character == L'\\' ? L'/' : character);
  }
  return uri;
}

std::wstring VersionText(const winrt::Windows::ApplicationModel::PackageVersion& version) {
  wchar_t buffer[32]{};
  swprintf_s(buffer, L"%hu.%hu.%hu.%hu", version.Major, version.Minor,
             version.Build, version.Revision);
  return buffer;
}

std::wstring ArchitectureName(winrt::Windows::System::ProcessorArchitecture architecture) {
  switch (architecture) {
    case winrt::Windows::System::ProcessorArchitecture::X86:
      return L"x86";
    case winrt::Windows::System::ProcessorArchitecture::Arm:
      return L"arm";
    case winrt::Windows::System::ProcessorArchitecture::X64:
      return L"x64";
    case winrt::Windows::System::ProcessorArchitecture::Arm64:
      return L"arm64";
    default:
      return L"neutral";
  }
}

InstalledPackage Describe(const Package& package) {
  InstalledPackage info;
  const auto id = package.Id();
  info.found = true;
  info.name = id.Name().c_str();
  info.publisher = id.Publisher().c_str();
  info.family_name = id.FamilyName().c_str();
  info.full_name = id.FullName().c_str();
  info.version = VersionText(id.Version());
  info.architecture = ArchitectureName(id.Architecture());
  const auto status = package.Status();
  info.status_ok = status.VerifyIsOK();
  info.needs_attention = !info.status_ok;
  return info;
}

bool ContainsIdentity(const std::wstring& name) {
  return _wcsicmp(name.c_str(), kIdentityName) == 0;
}

}  // namespace

std::wstring HResultMessage(HRESULT error) {
  wchar_t* buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, static_cast<DWORD>(error), 0,
      reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
  std::wstring message;
  if (length != 0 && buffer != nullptr) {
    message.assign(buffer, length);
    while (!message.empty() &&
           (message.back() == L'\r' || message.back() == L'\n')) {
      message.pop_back();
    }
  }
  LocalFree(buffer);
  return message;
}

bool QueryInstalledPackage(const std::wstring& identity_name,
                           InstalledPackage& out, std::wstring& error) {
  out = InstalledPackage{};
  try {
    PackageManager manager;
    for (const auto& package : manager.FindPackagesForUser(L"")) {
      const auto name = package.Id().Name().c_str();
      if (name == nullptr || _wcsicmp(name, identity_name.c_str()) != 0) {
        continue;
      }
      out = Describe(package);
      return true;
    }
    return true;
  } catch (const winrt::hresult_error& failure) {
    error = failure.message().c_str();
    return false;
  } catch (...) {
    error = L"package-manager-failed";
    return false;
  }
}

std::vector<InstalledPackage> FindPackagesForIdentity(
    const std::wstring& identity_name, std::wstring& error) {
  std::vector<InstalledPackage> packages;
  try {
    PackageManager manager;
    for (const auto& package : manager.FindPackagesForUser(L"")) {
      const auto name = package.Id().Name().c_str();
      if (name == nullptr || !ContainsIdentity(identity_name)) continue;
      packages.push_back(Describe(package));
    }
  } catch (const winrt::hresult_error& failure) {
    error = failure.message().c_str();
  } catch (...) {
    error = L"package-manager-failed";
  }
  return packages;
}

namespace {

PackageDeploymentResult DeployWithOptions(const std::wstring& package_path,
                                          DeploymentOptions options) {
  PackageDeploymentResult result;
  try {
    PackageManager manager;
    const auto dependencies =
        winrt::single_threaded_vector<winrt::Windows::Foundation::Uri>();
    const auto operation = manager.AddPackageAsync(
        Uri(winrt::hstring(FileUri(package_path))), dependencies, options);
    const DeploymentResult deployment = operation.get();
    if (deployment.IsRegistered()) {
      result.ok = true;
      return result;
    }
    result.error = deployment.ExtendedErrorCode();
    result.error_text = deployment.ErrorText().c_str();
    return result;
  } catch (const winrt::hresult_error& failure) {
    result.error = failure.code();
    result.error_text = failure.message().c_str();
    return result;
  } catch (...) {
    result.error = E_UNEXPECTED;
    result.error_text = L"unexpected";
    return result;
  }
}

}  // namespace

PackageDeploymentResult DeployPackage(const std::wstring& package_path) {
  return DeployWithOptions(package_path, DeploymentOptions::None);
}

PackageDeploymentResult RegisterInstalledPackage(
    const std::wstring& package_full_name) {
  PackageDeploymentResult result;
  try {
    PackageManager manager;
    const auto dependencies = winrt::single_threaded_vector<winrt::hstring>();
    const auto operation = manager.RegisterPackageByFullNameAsync(
        winrt::hstring(package_full_name), dependencies,
        DeploymentOptions::None);
    const DeploymentResult deployment = operation.get();
    if (deployment.IsRegistered()) {
      result.ok = true;
      return result;
    }
    result.error = deployment.ExtendedErrorCode();
    result.error_text = deployment.ErrorText().c_str();
    return result;
  } catch (const winrt::hresult_error& failure) {
    result.error = failure.code();
    result.error_text = failure.message().c_str();
    return result;
  } catch (...) {
    result.error = E_UNEXPECTED;
    result.error_text = L"unexpected";
    return result;
  }
}

bool ResolveAumid(const std::wstring& package_full_name, std::wstring& aumid,
                  std::wstring& error) {
  aumid.clear();
  try {
    PackageManager manager;
    for (const auto& package : manager.FindPackagesForUser(L"")) {
      const auto full_name = package.Id().FullName().c_str();
      if (full_name == nullptr ||
          _wcsicmp(full_name, package_full_name.c_str()) != 0) {
        continue;
      }
      const auto entries = package.GetAppListEntriesAsync().get();
      if (entries.Size() == 0) {
        error = L"no-app-list-entry";
        return false;
      }
      aumid = entries.GetAt(0).AppUserModelId().c_str();
      if (aumid.empty()) {
        error = L"empty-aumid";
        return false;
      }
      return true;
    }
    error = L"package-not-found";
    return false;
  } catch (const winrt::hresult_error& failure) {
    error = failure.message().c_str();
    return false;
  } catch (...) {
    error = L"aumid-query-failed";
    return false;
  }
}

bool IsPackageRunning(const std::wstring& family_name, DWORD& process_id) {
  process_id = 0;
  if (family_name.empty()) return false;
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return false;
  PROCESSENTRY32W entry{};
  entry.dwSize = sizeof(entry);
  bool found = false;
  if (Process32FirstW(snapshot, &entry)) {
    do {
      HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                                   entry.th32ProcessID);
      if (process == nullptr) continue;
      UINT32 length = 0;
      const LONG status = GetPackageFamilyName(process, &length, nullptr);
      if (status == ERROR_INSUFFICIENT_BUFFER && length > 0) {
        std::wstring name(length, L'\0');
        if (GetPackageFamilyName(process, &length, name.data()) == ERROR_SUCCESS) {
          while (!name.empty() && name.back() == L'\0') name.pop_back();
          if (_wcsicmp(name.c_str(), family_name.c_str()) == 0) {
            process_id = entry.th32ProcessID;
            found = true;
          }
        }
      }
      CloseHandle(process);
      if (found) break;
    } while (Process32NextW(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return found;
}

bool ActivateAumid(const std::wstring& aumid, DWORD& process_id,
                   std::wstring& error) {
  process_id = 0;
  if (aumid.empty()) {
    error = L"empty-aumid";
    return false;
  }
  IApplicationActivationManager* manager = nullptr;
  HRESULT hr = CoCreateInstance(CLSID_ApplicationActivationManager, nullptr,
                                CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(&manager));
  if (FAILED(hr)) {
    error = HResultMessage(hr);
    return false;
  }
  hr = manager->ActivateApplication(aumid.c_str(), nullptr, AO_NONE,
                                    &process_id);
  manager->Release();
  if (FAILED(hr)) {
    error = HResultMessage(hr);
    return false;
  }
  return true;
}

}  // namespace planner::native
