import "models.dart";

/// What a paste brings that is not text: files copied in a file manager, an
/// image copied on its own. Text on the clipboard is the field's to paste,
/// so where there is any, and no file list, there is nothing here.
abstract class ClipboardFiles {
  /// Asked when the user pastes. Empty when the clipboard holds text or
  /// nothing, and the field pastes as usual.
  Future<List<Attachment>> read();
}
