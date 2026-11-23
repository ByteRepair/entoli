import "package:flutter/foundation.dart";

/// Something went wrong and the app carried on.
///
/// Most failures here are caught and dropped on purpose — a launcher that
/// refuses an icon, a platform that will not hold the process, a cache that
/// answers 501 — because none of them is worth taking a turn down for. What
/// that costs is that they become indistinguishable from nothing having
/// happened, which is how a whole feature can be broken in nine places and
/// report none of them. This is the line that makes the difference.
///
/// [tag] is the layer, so a log can be read by whoever it is sent to: `sync`,
/// `files`, `icon`. Keep it short and reuse the ones already here.
///
/// **Nothing sensitive goes in one.** No secrets or keys, no message or file
/// contents, no prompt, no model output. A user pastes a log into an issue
/// without reading it; assume this one will be. An id and a reason.
///
/// Not gated on the build: a release build is the one somebody is running
/// when they tell you it did not work, and it goes to the terminal a desktop
/// was launched from or to `logcat`. Neither is somewhere an ordinary user
/// can reach, so this is for a developer reproducing a report rather than for
/// the report itself — a copyable log in Settings is what would change that.
///
/// For volume rather than failure — a subprocess's output, a cache hit — use
/// [logDetail].
void logFailure(String tag, String what, [Object? error]) =>
    debugPrint(error == null ? "[$tag] $what" : "[$tag] $what: $error");

/// The same, for what is worth seeing while developing and would drown a real
/// log: a subprocess line by line, a hit that is not a failure at all.
///
/// [what] is a callback so a release build allocates nothing: these run per
/// line of a model server's output, which is thousands of them a turn.
void logDetail(String tag, String Function() what) {
  if (kDebugMode) debugPrint("[$tag] ${what()}");
}
