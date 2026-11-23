import "package:flutter_riverpod/misc.dart" show Override;
import "package:entoli_core/transcript/host.dart" show transcriptHostProvider;
import "package:entoli_core/transcript/storage.dart" show fileSystemProvider;
import "package:entoli_core/view/chat/activity/card.dart"
    show transcriptHandOffProvider;
import "package:entoli_core/view/transcript_bindings.dart";

import "../app/composer.dart" show composerTextProvider;
import "../app/transcript_host.dart";
import "../providers.dart" show appConfigProvider;
import "../ui/chat/activity/context_hand_off.dart";
import "../ui/chat/widgets/composer_controller.dart";

/// The conversation's ports as the app binds them: the drawing ports, the
/// composer's field, the app as the transcript's host, and the disk as the
/// config's. `main` and the test harness bind the same list.
final appTranscriptOverrides = <Override>[
  ...transcriptOverrides,
  composerTextProvider.overrideWithValue(ComposerController.new),
  transcriptHostProvider.overrideWith(AppTranscriptHost.new),
  transcriptHandOffProvider.overrideWithValue(ContextHandOff.new),
  fileSystemProvider.overrideWith((ref) => ref.watch(appConfigProvider).fs),
];
