#include "update_storage_channel.h"

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.Storage.h>
#include <winrt/base.h>

#include <memory>
#include <string>

namespace {

using flutter::EncodableValue;
using flutter::MethodResult;

// 包身份是"能不能用 LocalCacheFolder"的前提；没有包身份时明确告诉 Dart 侧，
// 而不是让它去猜 `%LOCALAPPDATA%` 有没有被重定向。
bool HasPackageIdentity() {
  try {
    const auto package = winrt::Windows::ApplicationModel::Package::Current();
    const auto id = package.Id();
    return !id.Name().empty();
  } catch (...) {
    return false;
  }
}

}  // namespace

void RegisterUpdateStorageChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "personal_planner/update_storage",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const auto& call, std::unique_ptr<MethodResult<EncodableValue>> result) {
        if (call.method_name() != "getLocalCacheRoot") {
          result->NotImplemented();
          return;
        }
        if (!HasPackageIdentity()) {
          result->Error("UPDATE_STORAGE_UNPACKAGED",
                        "The process has no package identity.");
          return;
        }
        try {
          const auto folder =
              winrt::Windows::Storage::ApplicationData::Current()
                  .LocalCacheFolder();
          const auto path = folder.Path();
          if (path.empty()) {
            result->Error("UPDATE_STORAGE_FAILED",
                          "LocalCacheFolder returned an empty path.",
                          EncodableValue(static_cast<int32_t>(E_FAIL)));
            return;
          }
          result->Success(EncodableValue(winrt::to_string(path)));
        } catch (const winrt::hresult_error& error) {
          result->Error("UPDATE_STORAGE_FAILED", winrt::to_string(error.message()),
                        EncodableValue(static_cast<int32_t>(error.code())));
        } catch (...) {
          result->Error("UPDATE_STORAGE_FAILED",
                        "Unknown failure while resolving LocalCacheFolder.");
        }
      });
}
