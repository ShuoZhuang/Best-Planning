#ifndef RUNNER_WINDOW_CHANNEL_H_
#define RUNNER_WINDOW_CHANNEL_H_

#include <flutter/binary_messenger.h>

class FlutterWindow;

// Registers `personal_planner/window`, which carries the user's window preferences
// (currently: whether closing the window hides it to the tray or exits the app).
//
// The Dart side owns the setting's storage; this channel only applies it, so the native
// code holds no persistent state of its own.
void RegisterWindowChannel(flutter::BinaryMessenger* messenger,
                           FlutterWindow* window);

#endif  // RUNNER_WINDOW_CHANNEL_H_
