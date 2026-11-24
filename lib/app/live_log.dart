import "package:flutter/foundation.dart";

/// What a running task has said so far, for a page to show while it runs and
/// after. A [StringSink], so the task writes to it as it would to any stream;
/// [replace] is for a writer that hands over the whole output each time, as a
/// shell run's live tail does.
class LiveLog extends ChangeNotifier implements StringSink {
  final _text = StringBuffer();

  String get text => _text.toString();

  bool get isEmpty => _text.isEmpty;

  @override
  void write(Object? object) {
    _text.write(object);
    notifyListeners();
  }

  @override
  void writeln([Object? object = ""]) => write("$object\n");

  @override
  void writeAll(Iterable<dynamic> objects, [String separator = ""]) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  /// The whole log becomes [text].
  void replace(String text) {
    _text
      ..clear()
      ..write(text);
    notifyListeners();
  }

  void clear() => replace("");
}
