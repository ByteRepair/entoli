import "dart:async";

import "../../domain/llm_provider.dart";
import "../settings/cli_account.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A program's sign-in, for a provider that is a CLI, as a page of the
/// app's: its `CliAccount` run through — the program installed where Entoli
/// has no copy, its own sign-in started, the page it prints offered, a code
/// pasted back — and the page gone once the program says it is signed in.
/// [done] says whether it was.
class CliSignInAppPage extends AppPage {
  CliSignInAppPage(this.config, {this.again = false});

  final LlmProviderConfig config;

  /// Out of the account first, so the sign-in is a new one.
  final bool again;

  late final CliAccount _account;
  final _done = Completer<bool>();

  /// Whether the user signed in, once the page is gone.
  Future<bool> get done => _done.future;

  @override
  String get address => "cli-sign-in/${config.id}";

  @override
  void opened() {
    _account = CliAccount(container, config)..addListener(changed);
    _start();
  }

  void _start() => unawaited(
    _account.signIn(again: again).then((signedIn) {
      if (!signedIn || _done.isCompleted) return;
      _done.complete(true);
      pages.leave(this);
    }),
  );

  @override
  void closed() {
    _account.removeListener(changed);
    unawaited(_account.cancel().whenComplete(_account.dispose));
    if (!_done.isCompleted) _done.complete(false);
  }

  @override
  String title(SettingReader reader) => "Sign In to ${_account.plan}";

  NoticeController _line(String id, String text, {bool error = false}) =>
      NoticeController(
        part(id, ""),
        tone: error ? NoticeTone.warning : NoticeTone.plain,
        lines: [NoticeLine(text)],
      );

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("stage", "", switch (_account.stage) {
      CliInstalling(:final progress) => [
        _line(
          "installing",
          progress?.bar == null
              ? "Installing ${_account.cli.config.displayName}…"
              : "Installing ${_account.cli.config.displayName}… "
                    "${(progress!.bar! * 100).round()}%",
        ),
      ],
      CliChecking() || CliSignedIn() || CliSignedOut() => [
        _line("checking", "Checking whether you are signed in…"),
      ],
      CliStarting() => [_line("starting", "Starting the sign-in…")],
      CliWaiting(:final page) => [
        _line(
          "how",
          "Sign in with your ${_account.plan} account in your browser. This "
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
          value: "",
          prompt: "Code",
          submitLabel: "Send",
          onSet: (code) async {
            _account.answer(code);
            return null;
          },
        ),
      ],
      CliFailed(:final reason) => [
        _line("failed", reason, error: true),
        ActionController(
          part("retry", "Try Again"),
          run: () async {
            _start();
            return null;
          },
        ),
      ],
    }),
  ];
}
