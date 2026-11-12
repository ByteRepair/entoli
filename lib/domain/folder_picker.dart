/// Opens the platform's chooser for a folder or for files by their path.
/// Abstract so a page that adds one can be driven in a test, where no plugin
/// answers.
abstract class FolderPicker {
  /// The folder the user chose, or null if they cancelled.
  Future<String?> pick({required String confirmLabel});

  /// The files the user chose, by path; none if they cancelled.
  Future<List<String>> pickFiles({required String confirmLabel});
}
