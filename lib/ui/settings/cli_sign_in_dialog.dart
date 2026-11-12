import "dart:async";

import "package:flutter/material.dart";
import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/cli_account.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart";

/// Installs [account]'s program where Entoli has no copy of it, asks it
/// whether it is signed in, and where it is not, runs its sign-in — out of
/// its account first where [again]: the page it prints is shown here to
/// open, and a code the page shows can be pasted back. Pops true once the
/// program says it is signed in, false when cancelled.
class CliSignInDialog extends ConsumerStatefulWidget {
  const CliSignInDialog({super.key, required this.account, this.again = false});

  final CliAccount account;
  final bool again;

  @override
  ConsumerState<CliSignInDialog> createState() => _CliSignInDialogState();
}

class _CliSignInDialogState extends ConsumerState<CliSignInDialog> {
  final _code = TextEditingController();

  CliAccount get _account => widget.account;

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
    super.dispose();
  }

  /// A cancelled run returns false, so only a sign-in that landed pops here.
  Future<void> _run() async {
    if (await _account.signIn(again: widget.again) && mounted) {
      Navigator.pop(context, true);
    }
  }

  void _cancel() {
    unawaited(_account.cancel());
    Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _account,
    builder: (context, _) => AlertDialog(
      title: Text("Sign in to ${_account.plan}"),
      content: SizedBox(
        width: 420,
        child: switch (_account.stage) {
          CliInstalling(:final progress) => _Busy(
            "Installing ${_account.cli.config.displayName}…",
            value: progress?.bar,
          ),
          CliWaiting(:final page) => _SignInPage(
            plan: _account.plan,
            page: page,
            code: _code,
            onOpen: () =>
                ref.read(linkOpenerProvider).openSignIn(context, page),
            onCode: () => _account.answer(_code.text),
          ),
          CliStarting() => const _Busy("Starting the sign-in…"),
          CliFailed(:final reason) => Text(
            reason,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
          CliChecking() ||
          CliSignedIn() ||
          CliSignedOut() => const _Busy("Checking whether you are signed in…"),
        },
      ),
      actions: [
        TextButton(onPressed: _cancel, child: const Text("Cancel")),
        if (_account.stage is CliFailed)
          FilledButton(
            onPressed: () => unawaited(_run()),
            child: const Text("Try again"),
          ),
      ],
    ),
  );
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

/// The sign-in of [config]'s program where a provider on it is set up:
/// whether the account in the entry's own folder is signed in, as the
/// program says itself, and the way to sign it in — [CliSignInDialog], the
/// one the welcome tour opens — or, signed in, out and into another.
class CliAccountSection extends ConsumerStatefulWidget {
  const CliAccountSection({super.key, required this.config});

  final LlmProviderConfig config;

  @override
  ConsumerState<CliAccountSection> createState() => _CliAccountSectionState();
}

class _CliAccountSectionState extends ConsumerState<CliAccountSection> {
  late final _account = CliAccount(
    ProviderScope.containerOf(context, listen: false),
    widget.config,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_account.check());
  }

  @override
  void dispose() {
    _account.dispose();
    super.dispose();
  }

  Future<void> _signIn({bool again = false}) => showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => CliSignInDialog(account: _account, again: again),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: _account,
      builder: (context, _) => switch (_account.stage) {
        CliSignedIn() => Row(
          children: [
            Icon(Icons.check_circle, color: scheme.primary),
            const SizedBox(width: 12),
            Expanded(child: Text("Signed in to your ${_account.plan} account")),
            TextButton(
              onPressed: () => _signIn(again: true),
              child: const Text("Sign in again"),
            ),
          ],
        ),
        CliSignedOut() => Row(
          children: [
            Icon(Icons.account_circle_outlined, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            const Expanded(child: Text("Not signed in")),
            FilledButton.tonal(
              onPressed: _signIn,
              child: const Text("Sign in"),
            ),
          ],
        ),
        _ => const Row(
          children: [
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 12),
            Text("Checking the sign-in…"),
          ],
        ),
      },
    );
  }
}
