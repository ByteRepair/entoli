import "dart:async";

import "package:flutter/foundation.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../data/builtin/llm/providers/cli_sign_in.dart";
import "../../data/builtin/llm/providers/presets.dart" show CliProvider;
import "../../domain/download.dart";
import "../downloads/downloads.dart" show DownloadState;
import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../downloads/cli_downloads.dart";

/// Where a CLI program's account stands, and where a sign-in into it has got.
sealed class CliAccountStage {
  const CliAccountStage();

  /// Whether a sign-in is under way or has failed, which is what a frontend
  /// shows the steps of.
  bool get signingIn => false;
}

final class CliChecking extends CliAccountStage {
  const CliChecking();
}

final class CliSignedIn extends CliAccountStage {
  const CliSignedIn();
}

/// Also where the program is not there to ask, signing in being what
/// installs it.
final class CliSignedOut extends CliAccountStage {
  const CliSignedOut();
}

final class CliInstalling extends CliAccountStage {
  const CliInstalling(this.progress);

  final DownloadProgress? progress;

  @override
  bool get signingIn => true;
}

/// The program is started on its sign-in and has not named a page yet.
final class CliStarting extends CliAccountStage {
  const CliStarting();

  @override
  bool get signingIn => true;
}

/// Waiting on the user at [page], where a code the page shows may be pasted
/// back.
final class CliWaiting extends CliAccountStage {
  const CliWaiting(this.page);

  final Uri page;

  @override
  bool get signingIn => true;
}

final class CliFailed extends CliAccountStage {
  const CliFailed(this.reason);

  final String reason;

  @override
  bool get signingIn => true;
}

/// [config]'s program and its account, as both frontends draw it: whether it
/// is signed in, and a sign-in run through to the end — the program installed
/// where Entoli has no copy, its own sign-in started, the page it prints
/// named, a code pasted back.
class CliAccount extends ChangeNotifier {
  CliAccount(this._container, LlmProviderConfig config)
    : cli = cliProgramOf(_container.read(cliProgramsProvider), config);

  final ProviderContainer _container;
  final CliProvider cli;

  CliAccountStage _stage = const CliChecking();
  CliAccountStage get stage => _stage;

  /// What the program's account is called: "Claude", "ChatGPT".
  String get plan => cli.planName;

  CliSignIn? _signIn;

  /// Bumped by each run and by [cancel], so a run overtaken stops moving
  /// the stage.
  var _run = 0;
  var _disposed = false;

  void _show(CliAccountStage stage) {
    if (_disposed) return;
    _stage = stage;
    notifyListeners();
  }

  /// Asks the program whether it is signed in.
  Future<void> check() async {
    final run = ++_run;
    _show(const CliChecking());
    var signedIn = false;
    try {
      signedIn = cli.installed && await cli.signedIn();
    } catch (e) {
      logFailure("cli", "asking ${cli.config.displayName} its sign-in", e);
    }
    if (run == _run) {
      _show(signedIn ? const CliSignedIn() : const CliSignedOut());
    }
  }

  /// Installs the program where needed and signs it in; where [again], out
  /// of its account first, so the sign-in is a new one rather than the
  /// program saying it already is. True once it says it is signed in.
  Future<bool> signIn({bool again = false}) async {
    final run = ++_run;
    try {
      if (again) {
        _show(const CliChecking());
        try {
          await cli.signOut();
        } catch (e) {
          logFailure("cli", "signing ${cli.config.displayName} out", e);
        }
      }
      if (!cli.installed) await _install(run);
      if (run != _run) return false;
      _show(const CliChecking());
      if (await cli.signedIn()) {
        if (run == _run) _show(const CliSignedIn());
        return run == _run;
      }
      if (run != _run) return false;
      _show(const CliStarting());
      final signIn = _signIn = await CliSignIn.start(cli);
      if (run != _run || _disposed) {
        unawaited(signIn.cancel());
        return false;
      }
      // The page may be named again, a better one: the one the program asked
      // to open, which signs in with no code to paste.
      void named() {
        final page = signIn.page.value;
        if (run == _run && page != null) _show(CliWaiting(page));
      }

      named();
      signIn.page.addListener(named);
      final bool done;
      try {
        done = await signIn.result;
      } finally {
        signIn.page.removeListener(named);
        if (_signIn == signIn) _signIn = null;
      }
      if (run != _run) return false;
      _show(
        done
            ? const CliSignedIn()
            : CliFailed(signIn.failure ?? "The sign-in did not finish."),
      );
      return done;
    } catch (e) {
      logFailure("cli", "connecting ${cli.config.displayName} failed", e);
      if (run == _run) _show(CliFailed("$e"));
      return false;
    }
  }

  /// A code the page showed, for a program that asks for one to be pasted.
  void answer(String code) => _signIn?.answer(code);

  /// Stops a sign-in, and says where the account was left. The program is
  /// stopped behind this rather than before it returns: one that does not
  /// take its SIGTERM is given seconds more.
  Future<void> cancel() async {
    _run++;
    if (_signIn case final signIn?) unawaited(signIn.cancel());
    _signIn = null;
    if (_stage is CliInstalling) {
      _container.read(cliDownloadsProvider.notifier).cancel(cli.workFolder);
    }
    await check();
  }

  /// Through the shared downloads, so two sign-ins never fetch the program
  /// twice, and done once it is on disk.
  Future<void> _install(int run) async {
    final id = cli.workFolder;
    final done = Completer<void>();
    void landed(DownloadState state) {
      if (done.isCompleted) return;
      if (run == _run) _show(CliInstalling(state.active[id]));
      final failure = state.failures[id];
      if (failure != null) {
        done.completeError(failure);
      } else if (!state.active.containsKey(id)) {
        // Cancelled, or nothing this device could fetch, end it too.
        cli.installed
            ? done.complete()
            : done.completeError("${cli.config.displayName} was not installed");
      }
    }

    final sub = _container.listen<DownloadState>(
      cliDownloadsProvider,
      (_, state) => landed(state),
    );
    _show(const CliInstalling(null));
    _container.read(cliDownloadsProvider.notifier).install(cli);
    landed(_container.read(cliDownloadsProvider));
    try {
      await done.future;
    } finally {
      sub.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _run++;
    if (_signIn case final signIn?) unawaited(signIn.cancel());
    super.dispose();
  }
}
