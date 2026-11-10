import "dart:async";

import "../../../../core/log.dart";
import "cli.dart";

/// One sign-in of a CLI's program, run the way the program runs its own: it
/// prints a page to sign in on, waits while the user does, stores what the
/// page gave it — where every later session of it finds it — and exits 0.
///
/// Apart from [CliProvider] rather than a method on it, since this holds a
/// process for as long as the user takes, and the provider is a value.
class CliSignIn {
  CliSignIn._(this._provider, this._process) {
    _subs = [
      _process.lines.listen(_scan),
      // Error output comes in chunks rather than lines, so it is read a
      // whole line at a time: a link split between two chunks is not taken
      // at its first half.
      _process.errors.listen((chunk) => _scan(_errors.add(chunk))),
    ];
    result = _process.exitCode.then((code) async {
      final said = _errors.rest.trim();
      _scan(said);
      if (!_page.isCompleted) _page.complete(null);
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      final signedIn = code == 0 && !_cancelled && await _provider.signedIn();
      if (!signedIn) {
        _failure = "sign-in exited $code${said.isEmpty ? "" : ":\n$said"}";
        logFailure("cli", _failure!);
      }
      return signedIn;
    });
  }

  /// [provider]'s program, started on its [CliProvider.signInArguments] on a
  /// terminal: a program that asks for a code reads it as keys from one,
  /// and takes nothing written to a pipe.
  static Future<CliSignIn> start(CliProvider provider) async => CliSignIn._(
    provider,
    await provider.run(provider.signInArguments, terminal: true),
  );

  final CliProvider _provider;
  final CliProcess _process;
  late final List<StreamSubscription<String>> _subs;
  final _errors = _Lines();
  final _page = Completer<Uri?>();
  var _cancelled = false;

  /// What the program said on its error output as it ended, for a failed
  /// sign-in to explain itself; null once it succeeded.
  String? _failure;

  /// Why the sign-in failed, once [result] is false: the exit code and the
  /// program's own last words on its error output.
  String? get failure => _failure;

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
    return stopProcess(_process, _provider.config.displayName);
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

/// A stream that comes in chunks, read a whole line at a time: only the
/// line not yet ended is kept.
class _Lines {
  var _pending = "";

  /// The line not yet ended, which the end of the stream ends.
  String get rest => _pending;

  /// [chunk] added: the lines it ends, and nothing of the one it leaves open.
  String add(String chunk) {
    final text = _pending + chunk;
    final end = text.lastIndexOf("\n");
    if (end < 0) {
      _pending = text;
      return "";
    }
    _pending = text.substring(end + 1);
    return text.substring(0, end);
  }
}
