import "models.dart";

/// Opens the platform's file chooser and reads what comes back. Abstract so
/// the composer can be driven in a test, where no plugin answers.
abstract class AttachmentPicker {
  /// The files the user chose, or an empty list if they cancelled.
  Future<List<Attachment>> pick(AttachmentKind kind);
}
