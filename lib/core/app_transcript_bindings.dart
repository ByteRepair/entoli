import "package:flutter_riverpod/misc.dart" show Override;

import "../app/composer.dart" show composerTextProvider;
import "package:entoli_chat/app/transcript/host.dart"
    show transcriptHostProvider;
import "../app/transcript_host.dart";
import "package:entoli_chat/ui/chat/activity/card.dart"
    show transcriptHandOffProvider;
import "../ui/chat/activity/context_hand_off.dart";
import "../ui/chat/widgets/composer_controller.dart";
import "package:entoli_chat/core/transcript_bindings.dart";

/// The conversation's ports as the app binds them: the drawing ports, the
/// composer's field, and the app as the transcript's host. `main` and the
/// test harness bind the same list.
final appTranscriptOverrides = <Override>[
  ...transcriptOverrides,
  composerTextProvider.overrideWithValue(ComposerController.new),
  transcriptHostProvider.overrideWith(AppTranscriptHost.new),
  transcriptHandOffProvider.overrideWithValue(ContextHandOff.new),
];
