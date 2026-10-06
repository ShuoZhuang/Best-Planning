#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>
#include <string>

#include "tray_icon.h"
#include "win32_window.h"

// A window that hosts a Flutter view and a notification-area icon.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Whether closing the window hides it to the tray instead of exiting.
  //
  // Applied on request from Dart (the user's setting lives there), so the default is
  // false until Dart says otherwise: exiting is never worse than a window the user
  // cannot get rid of.
  void SetCloseToTray(bool close_to_tray);
  bool close_to_tray() const { return close_to_tray_; }

  // Whether the tray icon was added successfully.
  bool tray_icon_available() const { return tray_icon_ != nullptr; }

  // Why the tray icon is (not) available. Reported to Dart so a broken tray is
  // explainable instead of silently turning "close" into "exit".
  // Values: "ok", "icon_load_failed", "shell_add_failed:<GetLastError()>", "not_created".
  const std::string& tray_status() const { return tray_status_; }

  // Creates the tray icon if it does not exist yet. Idempotent.
  //
  // Called again from SetCloseToTray: the first attempt runs during window creation, and a
  // failure there (for example the shell not being ready yet at logon) must not leave the
  // app permanently unable to minimize to the tray.
  bool EnsureTrayIcon();

  // Ends the app. Called by the tray context menu's quit item.
  void QuitFromTray();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The notification-area icon. Present for the whole process lifetime so the quit item
  // stays reachable even while the setting is "closing exits directly".
  std::unique_ptr<TrayIcon> tray_icon_;

  bool close_to_tray_ = false;

  std::string tray_status_ = "not_created";
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
