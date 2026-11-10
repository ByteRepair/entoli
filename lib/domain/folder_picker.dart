/// Opens the platform's folder chooser. Abstract so a page that adds a folder
/// can be driven in a test, where no plugin answers.
abstract class FolderPicker {
  /// The folder the user chose, or null if they cancelled.
  Future<String?> pick({required String confirmLabel});
}
