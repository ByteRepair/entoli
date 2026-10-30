#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// agent_chat/clipboard: the copy with formatting, and the files a paste
// brings. See rich_clipboard.dart and clipboard_files.dart.
void clipboard_channel_register(FlView* view);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
