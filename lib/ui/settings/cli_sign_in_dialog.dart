import "dart:async";

import "package:flutter/material.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/pages/cli_sign_in.dart";
import "../../core/log.dart";
import "../../data/builtin/llm/providers/presets.dart";
import "../../domain/llm_provider.dart";
import "../../providers.dart";
import "../app_pages.dart";

/// [cliProgramOf] over this app's programs.
CliProvider programFor(WidgetRef ref, LlmProviderConfig config) =>
    cliProgramOf(ref.read(cliProgramsProvider), config);

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
  /// Null while the program is being asked; false also where it is not
  /// there to ask, signing in being what installs it.
  bool? _signedIn;

  late final CliProvider _cli = programFor(ref, widget.config);

  @override
  void initState() {
    super.initState();
    unawaited(_check());
  }

  Future<void> _check() async {
    if (mounted) setState(() => _signedIn = null);
    var signedIn = false;
    try {
      signedIn = _cli.installed && await _cli.signedIn();
    } catch (e) {
      logFailure("cli", "asking ${_cli.config.displayName} its sign-in", e);
    }
    if (mounted) setState(() => _signedIn = signedIn);
  }

  Future<void> _signIn() async {
    final page = CliSignInAppPage(_cli);
    openAppPage(context, page);
    if (await page.done) {
      if (mounted) setState(() => _signedIn = true);
    } else {
      await _check();
    }
  }

  /// Out of the account first, so the sign-in that follows is a new one
  /// rather than the program saying it already is. Given up on, it stays
  /// signed out, and says so.
  Future<void> _signInAgain() async {
    setState(() => _signedIn = null);
    try {
      await _cli.signOut();
    } catch (e) {
      logFailure("cli", "signing ${_cli.config.displayName} out", e);
    }
    if (mounted) await _signIn();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final plan = _cli.planName;
    return switch (_signedIn) {
      null => const Row(
        children: [
          SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 12),
          Text("Checking the sign-in…"),
        ],
      ),
      true => Row(
        children: [
          Icon(Icons.check_circle, color: scheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text("Signed in to your $plan account")),
          TextButton(
            onPressed: _signInAgain,
            child: const Text("Sign in again"),
          ),
        ],
      ),
      false => Row(
        children: [
          Icon(Icons.account_circle_outlined, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          const Expanded(child: Text("Not signed in")),
          FilledButton.tonal(onPressed: _signIn, child: const Text("Sign in")),
        ],
      ),
    };
  }
}
