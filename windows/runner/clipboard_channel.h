#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

// agent_chat/clipboard: the copy with formatting, and the files a paste
// brings. See rich_clipboard.dart and clipboard_files.dart.
void RegisterClipboardChannel(flutter::BinaryMessenger* messenger, HWND window);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
