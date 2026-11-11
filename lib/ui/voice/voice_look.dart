import "package:flutter/material.dart";

import "../../app/voice_controller.dart";
import "../theme.dart";

/// How the Flutter frontend says and colours voice mode's state.

/// What the screen says this is. The two words for a shut microphone are the
/// state's rather than the status's, which is why it is not all on the enum —
/// and they are two because a microphone waiting to be asked was never
/// paused.
extension VoiceWord on VoiceViewState {
  String get word => hushed ? (pushToTalk ? "Ready" : "Paused") : status.word;
}

extension VoiceStatusWord on VoiceStatus {
  String get word => switch (this) {
    VoiceStatus.off => "Off",
    VoiceStatus.starting => "Starting",
    VoiceStatus.listening => "Listening",
    VoiceStatus.thinking => "Thinking",
    VoiceStatus.speaking => "Speaking",
    VoiceStatus.failed => "Failed",
  };
}

/// What voice mode is drawn in, asked once by everything that draws it: the
/// orb, the dot beside the word, and the button that stops a reply.
Color voiceColour(VoiceViewState state, ThemeData theme) =>
    switch (state.status) {
      VoiceStatus.failed => theme.colorScheme.error,
      // Paused reads as off rather than as a state of listening, since that is
      // what it is: the device has stopped recording.
      _ when state.hushed => theme.colorScheme.onSurfaceVariant,
      VoiceStatus.speaking => spokenColour(theme.brightness),
      _ => heardColour(theme.brightness),
    };
