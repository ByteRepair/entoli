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

void respond_files(FlMethodCall* call, FlValue* files) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(files));
  fl_method_call_respond(call, response, nullptr);
  g_object_unref(call);
}

void got_uris(GtkClipboard*, gchar** uris, gpointer user) {
  auto* call = static_cast<FlMethodCall*>(user);
  g_autoptr(FlValue) files = fl_value_new_list();
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr; uri++) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path == nullptr) continue;
    FlValue* entry = fl_value_new_map();
    fl_value_set_string_take(entry, "path", fl_value_new_string(path));
    fl_value_append_take(files, entry);
  }
  g_strfreev(uris);
  respond_files(call, files);
}

void respond_image(FlMethodCall* call, const guchar* bytes, gsize size) {
  g_autoptr(FlValue) files = fl_value_new_list();
  if (bytes != nullptr && size > 0) {
    FlValue* entry = fl_value_new_map();
    fl_value_set_string_take(entry, "bytes",
                             fl_value_new_uint8_list(bytes, size));
    fl_value_append_take(files, entry);
  }
  respond_files(call, files);
}

void got_png(GtkClipboard*, GtkSelectionData* data, gpointer user) {
  gint size = data == nullptr ? 0 : gtk_selection_data_get_length(data);
  respond_image(static_cast<FlMethodCall*>(user),
                size > 0 ? gtk_selection_data_get_data(data) : nullptr,
                size > 0 ? size : 0);
}

// An image offered in some other format, converted to PNG here.
void got_image(GtkClipboard*, GdkPixbuf* pixbuf, gpointer user) {
  gchar* png = nullptr;
  gsize size = 0;
  if (pixbuf == nullptr ||
      !gdk_pixbuf_save_to_buffer(pixbuf, &png, &size, "png", nullptr, nullptr)) {
    size = 0;
  }
  respond_image(static_cast<FlMethodCall*>(user),
                reinterpret_cast<const guchar*>(png), size);
  g_free(png);
}

bool offers(GdkAtom* atoms, gint count, GdkAtom target) {
  for (gint i = 0; i < count; i++) {
    if (atoms[i] == target) return true;
  }
  return false;
}

// A file manager's copy carries the names as text too, so a file list wins
// over text, and text over an image: a spreadsheet's cells come with a
// picture of themselves.
void got_targets(GtkClipboard* clipboard, GdkAtom* atoms, gint count,
                 gpointer user) {
  auto* call = static_cast<FlMethodCall*>(user);
  if (atoms != nullptr && gtk_targets_include_uri(atoms, count)) {
    gtk_clipboard_request_uris(clipboard, got_uris, call);
  } else if (atoms != nullptr && !gtk_targets_include_text(atoms, count) &&
             gtk_targets_include_image(atoms, count, FALSE)) {
    GdkAtom png = gdk_atom_intern_static_string("image/png");
    if (offers(atoms, count, png)) {
      gtk_clipboard_request_contents(clipboard, png, got_png, call);
    } else {
      gtk_clipboard_request_image(clipboard, got_image, call);
    }
  } else {
    g_autoptr(FlValue) none = fl_value_new_list();
    respond_files(call, none);
  }
}

void handle(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "readFiles") == 0) {
    // Answered from the callbacks, which hold the call until then.
    gtk_clipboard_request_targets(gtk_clipboard_get(GDK_SELECTION_CLIPBOARD),
                                  got_targets, g_object_ref(call));
    return;
  }
  g_autoptr(FlMethodResponse) response =
      g_strcmp0(method, "setHtml") == 0
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
