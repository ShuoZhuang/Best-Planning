import 'package:flutter/material.dart';

/// How long an ordinary app message stays on screen.
const Duration plannerMessageDuration = Duration(seconds: 4);

/// A message that carries an action stays a little longer so the action can be
/// reached, but it still expires on its own.
const Duration plannerActionableMessageDuration = Duration(seconds: 8);

/// Builds the app's standard message bubble: a close control on the **left**,
/// the message, and an optional action on the right.
///
/// Two things are deliberate here and must not be dropped:
///
/// * **An explicit lifetime.** Flutter's [SnackBar] defaults `persist` to true
///   as soon as an action is present (`snack_bar.dart`: `persist = persist ??
///   action != null`), so an actionable bubble would otherwise never go away on
///   its own. Passing `persist: false` makes the timeout authoritative again.
/// * **A manual dismiss control on the left.** A message that reports something
///   the user has already read should be removable immediately, and the left
///   edge is where a close control is expected in this app.
SnackBar plannerSnackBar(
  ScaffoldMessengerState messenger, {
  required String message,
  SnackBarAction? action,
  Duration? duration,
}) {
  return SnackBar(
    duration:
        duration ??
        (action == null
            ? plannerMessageDuration
            : plannerActionableMessageDuration),
    persist: false,
    content: Row(
      children: [
        IconButton(
          key: const Key('snack-bar-close'),
          tooltip: '关闭提示',
          onPressed: messenger.hideCurrentSnackBar,
          icon: const Icon(Icons.close_rounded),
        ),
        const SizedBox(width: 4),
        Expanded(child: Text(message)),
      ],
    ),
    action: action,
  );
}

/// Shows an app message bubble through the nearest [ScaffoldMessenger].
///
/// Does nothing when there is no messenger, which is the same tolerance the
/// call sites had before (`ScaffoldMessenger.maybeOf`).
void showPlannerMessage(
  BuildContext context, {
  required String message,
  SnackBarAction? action,
  Duration? duration,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.showSnackBar(
    plannerSnackBar(
      messenger,
      message: message,
      action: action,
      duration: duration,
    ),
  );
}
