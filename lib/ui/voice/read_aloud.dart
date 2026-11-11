import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/read_aloud.dart";

export "../../app/read_aloud.dart";

/// What the preview in settings says, and the id it is read under. A question
/// and an answer's worth: enough to hear a voice's rhythm rather than one word
/// of it.
const previewSpeech = "Hi, how are you? What can I do for you?";
const previewId = "preview";

/// Read [said] out under [id], or stop if it is what is already being read,
/// and say in a snack bar what went wrong. Here rather than on the notifier
/// for the reason [ReadAloud.toggle] returns a string: the `Scaffold` is the
/// page's, and both of the buttons that read something out want the same
/// sentence over it.
Future<void> readAloud(
  BuildContext context,
  WidgetRef ref,
  String id,
  String said,
) async {
  final failed = await ref.read(readAloudProvider.notifier).toggle(id, said);
  if (failed == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed)));
}
