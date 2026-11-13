import "package:flutter_riverpod/flutter_riverpod.dart";

/// Whether the frontend draws the open chat and the new-chat screen itself,
/// from the app's state, the chat page then drawing none of it. The native
/// shell's does (`ShellChat`).
final drawsOpenChatProvider = Provider<bool>((ref) => false);
