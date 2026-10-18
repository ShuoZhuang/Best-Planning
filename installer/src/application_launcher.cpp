#include "application_launcher.h"

#include "native_shared/package_deployment.h"

namespace planner::installer {

LaunchResult LaunchInstalledApplication(const std::wstring& package_full_name) {
  LaunchResult result;
  std::wstring error;
  if (!planner::native::ResolveAumid(package_full_name, result.aumid, error)) {
    result.detail = L"resolve " + error;
    return result;
  }
  if (!planner::native::ActivateAumid(result.aumid, result.process_id, error)) {
    result.detail = L"activate " + error;
    return result;
  }
  result.ok = true;
  return result;
}

}  // namespace planner::installer
