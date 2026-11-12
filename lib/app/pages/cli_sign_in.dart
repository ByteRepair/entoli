import "dart:async";

import "../../core/log.dart";
import "../../data/builtin/llm/providers/cli_sign_in.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/download.dart";
import "../downloads/cli_downloads.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// Where a program's sign-in stands.
sealed class _Stage {
  const _Stage();
}

final class _Installing extends _Stage {
  const _Installing(this.progress);

  final DownloadProgress? progress;
}

final class _Checking extends _Stage {
  const _Checking();
}

final class _SigningIn extends _Stage {
  const _SigningIn(this.signIn);

  final CliSignIn signIn;
}

final class _Failed extends _Stage {
  const _Failed(this.reason);

  final String reason;
}

/// A program's own sign-in, run for a provider that is a CLI: installed
/// first where it is not, then its sign-in page opened in the browser and,
/// where the page shows a code instead, the code pasted back. It carries on
/// by itself once the user has signed in; [done] says whether they did.
class CliSignInAppPage extends AppPage {
  CliSignInAppPage(this.cli);

  final CliProvider cli;

  _Stage _stage = const _Checking();
  String _code = "";
  final _done = Completer<bool>();

  /// Whether the user signed in, once the page is gone.
  Future<bool> get done => _done.future;

  @override
  String get address => "cli-sign-in/${cli.workFolder}";

  @override
  void opened() => unawaited(_run());

  void _show(_Stage stage) {
    _stage = stage;
    changed();
  }

  Future<void> _run() async {
    try {
      if (!cli.installed) await _install();
      _show(const _Checking());
      if (await cli.signedIn()) return _finish(true);
      final signIn = await CliSignIn.start(cli);
      if (_done.isCompleted) return unawaited(signIn.cancel());
      _show(_SigningIn(signIn));
      signIn.page.addListener(changed);
      try {
        if (await signIn.result) return _finish(true);
      } finally {
        signIn.page.removeListener(changed);
      }
      _show(_Failed(signIn.failure ?? "The sign-in did not finish."));
    } catch (e) {
      logFailure("cli", "connecting ${cli.config.displayName} failed", e);
      _show(_Failed("$e"));
    }
  }

  Future<void> _install() async {
    final id = cli.workFolder;
    final finished = Completer<void>();
    final sub = listen(cliDownloadsProvider, (_, state) {
      if (finished.isCompleted) return;
      _show(_Installing(state.active[id]));
      final failure = state.failures[id];
      if (failure != null) {
        finished.completeError(failure);
      } else if (!state.active.containsKey(id) && cli.installed) {
        finished.complete();
      }
    });
    _show(const _Installing(null));
    app.read(cliDownloadsProvider.notifier).install(cli);
    try {
      await finished.future;
    } finally {
      sub.close();
    }
  }

  void _finish(bool signedIn) {
    if (_done.isCompleted) return;
    _done.complete(signedIn);
    pages.leave(this);
  }

  @override
  void closed() {
    final stage = _stage;
    if (stage is _SigningIn) unawaited(stage.signIn.cancel());
    if (stage is _Installing) {
      app.read(cliDownloadsProvider.notifier).cancel(cli.workFolder);
    }
    if (!_done.isCompleted) _done.complete(false);
  }

  @override
  String title(SettingReader reader) => "Sign In to ${cli.planName}";

  NoticeController _line(String id, String text, {bool error = false}) =>
      NoticeController(
        part(id, ""),
        tone: error ? NoticeTone.warning : NoticeTone.plain,
        lines: [NoticeLine(text)],
      );

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("stage", "", switch (_stage) {
      _Installing(:final progress) => [
        _line(
          "installing",
          progress?.bar == null
              ? "Installing ${cli.config.displayName}…"
              : "Installing ${cli.config.displayName}… "
                    "${(progress!.bar! * 100).round()}%",
        ),
      ],
      _Checking() => [_line("checking", "Checking whether you are signed in…")],
      _SigningIn(:final signIn) => switch (signIn.page.value) {
        null => [_line("starting", "Starting the sign-in…")],
        final page => [
          _line(
            "how",
            "Sign in with your ${cli.planName} account in your browser. This "
                "page carries on by itself once you have.",
          ),
          InfoController(
            part("open", "Sign-in page", hint: UiHint.info),
            rows: [
              InfoRow(
                "Open the Sign-in Page",
                subtitle: "$page",
                link: page,
                glyph: SettingGlyph.globe,
              ),
            ],
          ),
          ActionController(
            part("copy", "Copy the Link"),
            label: "Copy the Link",
            secondary: true,
            run: () async => SettingNotice("Copied link", copy: "$page"),
          ),
          TextController(
            part(
              "code",
              "Code",
              hint: UiHint.input,
              description: "If the page shows a code instead, paste it here.",
            ),
            value: _code,
            prompt: "Code",
            submitLabel: "Send",
            onSet: (code) async {
              _code = code;
              signIn.answer(code);
              return null;
            },
          ),
        ],
      },
      _Failed(:final reason) => [
        _line("failed", reason, error: true),
        ActionController(
          part("retry", "Try Again"),
          label: "Try Again",
          run: () async {
            _show(const _Checking());
            unawaited(_run());
            return null;
          },
        ),
      ],
    }),
  ];
}
