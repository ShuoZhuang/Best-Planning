#include "window_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "flutter_window.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodResult;

const EncodableValue* Find(const EncodableMap& arguments, const char* key) {
  const auto iterator = arguments.find(EncodableValue(key));
  return iterator == arguments.end() ? nullptr : &iterator->second;
}

}  // namespace

void RegisterWindowChannel(flutter::BinaryMessenger* messenger,
                           FlutterWindow* window) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "personal_planner/window",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window](const auto& call,
               std::unique_ptr<MethodResult<EncodableValue>> result) {
        if (call.method_name() != "setCloseBehavior") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        if (arguments == nullptr || window == nullptr) {
          result->Error("invalid_arguments",
                        "setCloseBehavior needs an arguments map.");
          return;
        }
        const auto* minimize = Find(*arguments, "minimizeToTray");
        const auto* value =
            minimize == nullptr ? nullptr : std::get_if<bool>(minimize);
        if (value == nullptr) {
          result->Error("invalid_arguments",
                        "minimizeToTray must be a boolean.");
          return;
        }
        window->SetCloseToTray(*value);
        // Report whether the tray icon is actually present **and why not when it is not**,
        // so the Dart side can tell the user instead of silently exiting on close.
        EncodableMap status;
        status[EncodableValue("available")] =
            EncodableValue(window->tray_icon_available());
        status[EncodableValue("status")] =
            EncodableValue(window->tray_status());
        result->Success(EncodableValue(status));
      });
}
