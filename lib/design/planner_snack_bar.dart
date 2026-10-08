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
/// **Tolerates having nowhere to show it.** A `ScaffoldMessenger` can exist with no descendant
/// [Scaffold] to present to — `MaterialApp` provides the messenger, so a page pumped bare in a
/// widget test (or hosted in a route without a scaffold) hits exactly that. `showSnackBar` then
/// *asserts* (`_scaffolds.isNotEmpty`) and throws, which turns a message that could not be shown
/// into a crash in the calling flow. Since this helper is called after a state change has already
/// been applied, throwing here would report the wrong thing: the action succeeded.
///
/// So: no messenger, or nothing to present to ⇒ the message is simply dropped. Both cases are
/// recorded by [canShowPlannerMessage] so a test can distinguish "not drawn" from "cannot be drawn".
void showPlannerMessage(
  BuildContext context, {
  required String message,
  SnackBarAction? action,
  Duration? duration,
}) {
  if (!canShowPlannerMessage(context)) return;
  final messenger = ScaffoldMessenger.maybeOf(context)!;
  messenger.showSnackBar(
    plannerSnackBar(
      messenger,
      message: message,
      action: action,
      duration: duration,
    ),
  );
}

/// Whether [showPlannerMessage] would actually be able to present a bubble from [context].
///
/// Two conditions, both required: a [ScaffoldMessenger] must be reachable, **and** it must have at
/// least one descendant [Scaffold]. Callers that must not silently lose a message can check this
/// and choose another surface; the today page uses it so its own tests stay honest about whether a
/// bubble was expected.
bool canShowPlannerMessage(BuildContext context) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return false;
  // `ScaffoldMessengerState` exposes registered scaffolds only through its internal state; the
  // public, documented proxy is `Scaffold.maybeOf` walking down from the context. A context that
  // is inside a `Scaffold` subtree has one; the messenger alone does not imply it.
  return context.findAncestorStateOfType<ScaffoldMessengerState>() != null &&
      _hasScaffoldAncestor(context);
}

/// `Scaffold.maybeOf` walks **up**, so it answers "is this context inside a Scaffold".
/// A page pumped bare is not, and that is precisely the case that used to assert.
bool _hasScaffoldAncestor(BuildContext context) =>
    Scaffold.maybeOf(context) != null;
