import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../core/log.dart";
import "../../data/builtin/llm/providers/cli_sign_in.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/download.dart";
import "../../providers.dart";
import "../widgets/provider_dialog.dart";
import "cli_downloads.dart";

/// Connects [service] the way its user knows it: a CLI is installed and
/// signed in, and an API is its preset's dialog. Either way it is adopted —
/// it answers new chats at its own defaults.
Future<void> connectService(
  BuildContext context,
  WidgetRef ref,
  OfferedByName service,
) => switch (service) {
  CliProvider() => _connectCli(context, ref, service),
  _ => editProvider(
    context,
    ref,
    initial: service.config,
    title: "Connect ${service.displayName}",
    adopt: true,
  ),
};

/// [service]'s program, Entoli's own copy of it installed where it is not
/// yet and signed in where it is not yet, added once it is — or, where an
/// entry for it is already configured, that entry adopted rather than a
/// second one added beside it.
Future<void> _connectCli(
  BuildContext context,
  WidgetRef ref,
  OfferedByName service,
) async {
  // Notifier first: the page that asked can go away while the dialog is
  // open, and the save must outlive it.
  final notifier = ref.read(appSettingsProvider.notifier);
  final cli = ref
      .read(cliProgramsProvider)
      .firstWhere((c) => c.config.api == service.config.api);
  final ready = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CliSignInDialog(cli: cli, service: service),
  );
  if (ready != true) return;
  final existing = ref
      .read(appSettingsProvider)
      .llmProviders
      .where((p) => p.api == cli.config.api && p.command == null)
      .firstOrNull;
  await notifier.upsertProvider(existing ?? cli.config, adopt: true);
}

/// Where a sign-in has got to.
sealed class _Stage {
  const _Stage();
}

class _Installing extends _Stage {
  const _Installing(this.progress);

  final DownloadProgress? progress;
}

class _Checking extends _Stage {
  const _Checking();
}

class _SigningIn extends _Stage {
  const _SigningIn(this.signIn, this.page);

  final CliSignIn signIn;

  /// Null until the program prints it.
  final Uri? page;
}

class _Failed extends _Stage {
  const _Failed(this.reason);

  final String reason;
}

/// Installs [cli] where Entoli has no copy of it, asks it whether it is
/// signed in, and where it is not, runs its sign-in: the page it prints is
/// shown here to open, and a code the page shows can be pasted back. Pops
/// true once the program says it is signed in, false when cancelled.
class CliSignInDialog extends ConsumerStatefulWidget {
  const CliSignInDialog({super.key, required this.cli, required this.service});

  final CliProvider cli;

  /// The words the service is shown with, which [cli] may be a stand-in for.
  final OfferedByName service;

  @override
  ConsumerState<CliSignInDialog> createState() => _CliSignInDialogState();
}

class _CliSignInDialogState extends ConsumerState<CliSignInDialog> {
  _Stage _stage = const _Checking();
  final _code = TextEditingController();

  CliProvider get _cli => widget.cli;
  String get _name => widget.service.serviceName;

  @override
  void initState() {
    super.initState();
    // After the first frame: starting a download is a provider write, which
    // may not happen while the tree builds.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    _code.dispose();
    final stage = _stage;
    if (stage is _SigningIn) unawaited(stage.signIn.cancel());
    super.dispose();
  }

  void _show(_Stage stage) {
    if (mounted) setState(() => _stage = stage);
  }

  Future<void> _run() async {
    try {
      if (!_cli.installed) await _install();
      if (!mounted) return;
      _show(const _Checking());
      if (await _cli.signedIn()) return _finish(true);
      final signIn = await CliSignIn.start(_cli);
      if (!mounted) return unawaited(signIn.cancel());
      _show(_SigningIn(signIn, null));
      unawaited(
        signIn.page.then((page) {
          final stage = _stage;
          if (page != null && stage is _SigningIn && stage.signIn == signIn) {
            _show(_SigningIn(signIn, page));
          }
        }),
      );
      if (await signIn.result) return _finish(true);
      _show(const _Failed("The sign-in did not finish."));
    } catch (e) {
      logFailure("cli", "connecting ${_cli.config.displayName} failed", e);
      _show(_Failed("$e"));
    }
  }

  /// Through the shared downloads, so first-run setup and this one never
  /// fetch the program twice, and done once it is on disk.
  Future<void> _install() async {
    final id = _cli.workFolder;
    final done = Completer<void>();
    final sub = ref.listenManual(cliDownloadsProvider, (_, state) {
      if (done.isCompleted) return;
      _show(_Installing(state.active[id]));
      final failure = state.failures[id];
      if (failure != null) {
        done.completeError(failure);
      } else if (!state.active.containsKey(id) && _cli.installed) {
        done.complete();
      }
    });
    _show(const _Installing(null));
    ref.read(cliDownloadsProvider.notifier).install(_cli);
    try {
      await done.future;
    } finally {
      sub.close();
    }
  }

  /// Out of [_SigningIn] first, so closing does not stop a program that
  /// has already finished.
  void _finish(bool signedIn) {
    _stage = const _Checking();
    if (mounted) Navigator.pop(context, signedIn);
  }

  Future<void> _cancel() async {
    final stage = _stage;
    if (stage is _SigningIn) await stage.signIn.cancel();
    if (stage is _Installing) {
      ref.read(cliDownloadsProvider.notifier).cancel(_cli.workFolder);
    }
    _finish(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text("Connect $_name"),
      content: SizedBox(
        width: 420,
        child: switch (_stage) {
          _Installing(:final progress) => _Busy(
            "Installing ${_cli.config.displayName}…",
            value: progress?.bar,
          ),
          _Checking() => const _Busy("Checking whether you are signed in…"),
          _SigningIn(page: null) => const _Busy("Starting the sign-in…"),
          _SigningIn(:final signIn, page: final Uri page) => _SignInPage(
            plan: _cli.planName,
            page: page,
            code: _code,
            onOpen: () => ref.read(linkOpenerProvider).open(context, page),
            onCode: () => signIn.answer(_code.text),
          ),
          _Failed(:final reason) => Text(
            reason,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        },
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text("Cancel")),
        if (_stage is _Failed)
          FilledButton(
            onPressed: () {
              _show(const _Checking());
              unawaited(_run());
            },
            child: const Text("Try again"),
          ),
      ],
    );
  }
}

class _Busy extends StatelessWidget {
  const _Busy(this.text, {this.value});

  final String text;
  final double? value;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(text),
      const SizedBox(height: 16),
      LinearProgressIndicator(value: value),
    ],
  );
}

/// The page to sign in on, a way to open it and to copy it, and a field for
/// a code the page may hand back instead of returning on its own.
class _SignInPage extends StatelessWidget {
  const _SignInPage({
    required this.plan,
    required this.page,
    required this.code,
    required this.onOpen,
    required this.onCode,
  });

  final String plan;
  final Uri page;
  final TextEditingController code;
  final VoidCallback onOpen;
  final VoidCallback onCode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          "Sign in with your $plan account in your browser. This window "
          "carries on by itself once you have.",
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text("Open the sign-in page"),
          onPressed: onOpen,
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          icon: const Icon(Icons.copy),
          label: const Text("Copy the link"),
          onPressed: () => Clipboard.setData(ClipboardData(text: "$page")),
        ),
        const SizedBox(height: 16),
        Text(
          "If the page shows a code instead, paste it here.",
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: code,
          decoration: InputDecoration(
            hintText: "Code",
            suffixIcon: IconButton(
              tooltip: "Send the code",
              icon: const Icon(Icons.send),
              onPressed: onCode,
            ),
          ),
          onSubmitted: (_) => onCode(),
        ),
        const SizedBox(height: 16),
        const LinearProgressIndicator(),
      ],
    );
  }
}
