import "dart:async";

import "cli.dart";

/// One sign-in of a CLI's program, run the way the program runs its own: it
/// prints a page to sign in on, waits while the user does, stores what the
/// page gave it — where every later session of it finds it — and exits 0.
///
/// Apart from [CliProvider] rather than a method on it, since this holds a
/// process for as long as the user takes, and the provider is a value.
class CliSignIn {
  CliSignIn._(this.provider, this._process) {
    _subs = [
      _process.lines.listen(_scan),
      // Error output comes in chunks rather than lines, so it is read a
      // whole line at a time: a link split between two chunks is not taken
      // at its first half.
      _process.errors.listen((chunk) => _scan(_errors.lines(chunk))),
    ];
    result = _process.exitCode.then((code) async {
      _scan(_errors.all);
      if (!_page.isCompleted) _page.complete(null);
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      return code == 0 && !_cancelled && await provider.signedIn();
    });
  }

  /// [provider]'s program, started on its [CliProvider.signInArguments].
  static Future<CliSignIn> start(CliProvider provider) async =>
      CliSignIn._(provider, await provider.run(provider.signInArguments));

  final CliProvider provider;
  final CliProcess _process;
  late final List<StreamSubscription<String>> _subs;
  final _errors = _Collected();
  final _page = Completer<Uri?>();
  var _cancelled = false;

  /// The first link the program prints, which is the page to sign in on;
  /// null where it exits having printed none.
  Future<Uri?> get page => _page.future;

  /// Whether it ended signed in: the program exited 0, and its own status
  /// says so.
  late final Future<bool> result;

  /// A code the page showed, for a program that asks for one to be pasted.
  void answer(String code) => _process.writeLine(code.trim());

  /// Stops waiting: the program is ended, and [result] is false.
  Future<void> cancel() {
    _cancelled = true;
    return stopProcess(_process, provider.config.displayName);
  }

  void _scan(String text) {
    if (_page.isCompleted) return;
    final link = _link.firstMatch(text)?[0];
    if (link != null) _page.complete(Uri.parse(link));
  }

  /// A link up to whatever cannot be in one: space, a quote, an angle
  /// bracket, or the escape that starts a terminal colour.
  static final _link = RegExp("https://[^\\s\"'<>\\x1b]+");
}

/// What has arrived of a stream that comes in chunks.
class _Collected {
  final _buffer = StringBuffer();

  /// Everything so far, the last line whether or not it has ended.
  String get all => "$_buffer";

  /// [chunk] added, and every line so far that has ended.
  String lines(String chunk) {
    final text = (_buffer..write(chunk)).toString();
    final end = text.lastIndexOf("\n");
    return end < 0 ? "" : text.substring(0, end);
  }
}
