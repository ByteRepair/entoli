#include "clipboard_channel.h"

#include <gtk/gtk.h>

namespace {

enum Target : guint { kHtml, kText };

struct Payload {
  gchar* plain;
  gchar* html;
};

// The clipboard holds no bytes of ours; a paste asks for one target and is
// answered from the payload, kept until another owner takes the clipboard.
void get_cb(GtkClipboard*, GtkSelectionData* data, guint info, gpointer user) {
  auto* payload = static_cast<Payload*>(user);
  if (info == kHtml) {
    gtk_selection_data_set(data, gtk_selection_data_get_target(data), 8,
                           reinterpret_cast<const guchar*>(payload->html),
                           strlen(payload->html));
  } else {
    gtk_selection_data_set_text(data, payload->plain, -1);
  }
}

void clear_cb(GtkClipboard*, gpointer user) {
  auto* payload = static_cast<Payload*>(user);
  g_free(payload->plain);
  g_free(payload->html);
  g_free(payload);
}

FlMethodResponse* set_html(FlValue* args) {
  FlValue* plain = fl_value_get_type(args) == FL_VALUE_TYPE_MAP
                       ? fl_value_lookup_string(args, "plain")
                       : nullptr;
  FlValue* html = plain == nullptr ? nullptr : fl_value_lookup_string(args, "html");
  if (html == nullptr || fl_value_get_type(plain) != FL_VALUE_TYPE_STRING ||
      fl_value_get_type(html) != FL_VALUE_TYPE_STRING) {
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("bad-args", "plain and html", nullptr));
  }
  g_autoptr(GtkTargetList) list = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add(list, gdk_atom_intern_static_string("text/html"), 0, kHtml);
  gtk_target_list_add_text_targets(list, kText);
  gint count = 0;
  GtkTargetEntry* targets = gtk_target_table_new_from_list(list, &count);

  auto* payload = g_new0(Payload, 1);
  payload->plain = g_strdup(fl_value_get_string(plain));
  payload->html = g_strdup(fl_value_get_string(html));
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gboolean owned = gtk_clipboard_set_with_data(clipboard, targets, count,
                                               get_cb, clear_cb, payload);
  gtk_target_table_free(targets, count);
  if (!owned) {
    clear_cb(clipboard, payload);
    return FL_METHOD_RESPONSE(
        fl_method_error_response_new("unowned", "clipboard refused", nullptr));
  }
  // A clipboard manager keeps the copy once this process has gone.
  gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

void handle(FlMethodChannel*, FlMethodCall* call, gpointer) {
  g_autoptr(FlMethodResponse) response =
      g_strcmp0(fl_method_call_get_name(call), "setHtml") == 0
          ? set_html(fl_method_call_get_args(call))
          : FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(call, response, nullptr);
}

}  // namespace

void clipboard_channel_register(FlView* view) {
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  // Lives as long as the app: nothing unregisters it.
  FlMethodChannel* channel = fl_method_channel_new(
      messenger, "agent_chat/clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, handle, nullptr, nullptr);
}
