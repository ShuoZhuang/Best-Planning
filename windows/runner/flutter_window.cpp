#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"
#include "timetable_ocr_channel.h"
#include "window_channel.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterTimetableOcrChannel(flutter_controller_->engine()->messenger());
  RegisterWindowChannel(flutter_controller_->engine()->messenger(), this);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The tray icon exists for the whole process lifetime: it is the only way back to a
  // window the user closed, and the only way to exit once closing hides the window.
  EnsureTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Remove the tray icon before the window goes away: the shell would otherwise keep a
  // dead entry until the user hovers over it.
  tray_icon_.reset();

  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::EnsureTrayIcon() {
  if (tray_icon_ != nullptr) {
    return true;
  }
  HICON icon =
      ::LoadIconW(::GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (icon == nullptr) {
    tray_status_ = "icon_load_failed";
    return false;
  }
  // Check the window handle explicitly. Without this, `TrayIcon::Add` would return false
  // for a null handle *without ever calling the shell*, and the caller would then read a
  // stale GetLastError() and report a bogus "shell_add_failed:N".
  HWND handle = GetHandle();
  if (handle == nullptr) {
    tray_status_ = "no_window_handle";
    return false;
  }
  // The tooltip repeats the window title; \u escapes keep this file pure ASCII (see the
  // note in tray_icon.cpp about code page 936 and warning C4819).
  auto tray = std::make_unique<TrayIcon>(handle, icon,
                                         L"\u667A\u80FD\u65E5\u7A0B",
                                         [this]() { QuitFromTray(); });
  if (!tray->Add()) {
    // Report the shell's own error: it is the only clue to why there is no icon, and the
    // user-visible symptom ("closing the window ended the app") explains nothing.
    //
    // Already ruled out on this machine, each by building and running it: the
    // NOTIFYICONDATA size (modern vs the pre-Vista offset), the callback message
    // (registered vs WM_APP + n), the icon (the app's .ico vs IDI_APPLICATION), and the
    // window (the Flutter window vs a plain STATIC window created by this same process).
    // All of them fail with ERROR_ACCESS_DENIED *from this process* while an identical call
    // from an unrestricted process on the same desktop succeeds - i.e. the denial is a
    // property of the process context, not of the arguments. So keep exactly one attempt
    // and carry the error out instead of retrying in the hope that something changes.
    tray_status_ = "shell_add_failed:" + std::to_string(::GetLastError());
    return false;
  }
  tray_status_ = "ok";
  tray_icon_ = std::move(tray);
  return true;
}

void FlutterWindow::SetCloseToTray(bool close_to_tray) {
  if (close_to_tray) {
    EnsureTrayIcon();
  }
  // Refuse the setting when there is no tray icon: with it, closing the window would hide
  // the only window while leaving no way to bring it back or to exit.
  close_to_tray_ = close_to_tray && tray_icon_available();
}

void FlutterWindow::QuitFromTray() {
  tray_icon_.reset();
  Destroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (tray_icon_ && message == TrayIcon::CallbackMessage() &&
      tray_icon_->HandleMessage(wparam, lparam)) {
    return 0;
  }

  switch (message) {
    case WM_CLOSE:
      // "Minimize to the background": hide the window and keep the process (and the
      // scheduler) running. Not chaining to the base class here is what stops
      // DefWindowProc from destroying the window and ending the app.
      //
      // Session end (WM_QUERYENDSESSION / WM_ENDSESSION) is deliberately left alone, so
      // shutting Windows down still ends the app instead of stranding it in the tray.
      if (close_to_tray_) {
        ::ShowWindow(hwnd, SW_HIDE);
        return 0;
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
