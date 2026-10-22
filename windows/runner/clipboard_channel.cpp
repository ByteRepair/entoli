#include "clipboard_channel.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <variant>

namespace {

// CF_HTML is the document behind a header of byte offsets into itself. Every
// offset field is ten digits wide, so the header's own length is known before
// any of them is.
std::string HtmlFormat(const std::string& html) {
  const char* kStart = "<!--StartFragment-->";
  const char* kEnd = "<!--EndFragment-->";
  constexpr char kHeader[] =
      "Version:0.9\r\nStartHTML:%010zu\r\nEndHTML:%010zu\r\n"
      "StartFragment:%010zu\r\nEndFragment:%010zu\r\n";
  const size_t header = std::snprintf(nullptr, 0, kHeader, size_t{0}, size_t{0},
                                      size_t{0}, size_t{0});
  size_t start = html.find(kStart);
  size_t end = html.find(kEnd);
  start = start == std::string::npos ? 0 : start + std::strlen(kStart);
  end = end == std::string::npos ? html.size() : end;
  std::string out(header + 1, '\0');
  std::snprintf(out.data(), out.size(), kHeader, header, header + html.size(),
                header + start, header + end);
  out.resize(header);
  return out + html;
}

bool Put(UINT format, const void* bytes, size_t size) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  if (memory == nullptr) return false;
  std::memcpy(GlobalLock(memory), bytes, size);
  GlobalUnlock(memory);
  // The clipboard owns the memory once this succeeds, and not before.
  if (SetClipboardData(format, memory) == nullptr) {
    GlobalFree(memory);
    return false;
  }
  return true;
}

bool SetHtml(HWND window, const std::string& plain, const std::string& html) {
  const int wide = MultiByteToWideChar(CP_UTF8, 0, plain.c_str(), -1, nullptr, 0);
  std::wstring text(wide, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, plain.c_str(), -1, text.data(), wide);
  const std::string document = HtmlFormat(html);

  if (!OpenClipboard(window)) return false;
  EmptyClipboard();
  const bool ok =
      Put(RegisterClipboardFormatW(L"HTML Format"), document.c_str(),
          document.size() + 1) &&
      Put(CF_UNICODETEXT, text.c_str(), text.size() * sizeof(wchar_t));
  CloseClipboard();
  return ok;
}

}  // namespace

void RegisterClipboardChannel(flutter::BinaryMessenger* messenger, HWND window) {
  // Lives as long as the app: nothing unregisters it.
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel;
  channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "agent_chat/clipboard",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window](const auto& call, auto result) {
    if (call.method_name() != "setHtml") return result->NotImplemented();
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    const std::string* plain = nullptr;
    const std::string* html = nullptr;
    if (args != nullptr) {
      auto p = args->find(flutter::EncodableValue("plain"));
      auto h = args->find(flutter::EncodableValue("html"));
      if (p != args->end()) plain = std::get_if<std::string>(&p->second);
      if (h != args->end()) html = std::get_if<std::string>(&h->second);
    }
    if (plain == nullptr || html == nullptr) {
      return result->Error("bad-args", "plain and html");
    }
    if (!SetHtml(window, *plain, *html)) {
      return result->Error("unowned", "clipboard refused");
    }
    result->Success();
  });
}
