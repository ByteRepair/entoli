import "dart:async";

import "package:entoli_glass/entoli_glass.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";

import "../../app/settings/cli_account.dart";
import "../../core/log.dart";
import "../../domain/llm_provider.dart";

/// The native form's program account: the core's [CliAccount], sent to the
/// client as it moves, while the client shows its row. One at a time, there
/// being one form open.
class ShellCliAccount {
  ShellCliAccount(this._container, this._native);

  final ProviderContainer _container;
  final NativeSettings _native;
  CliAccount? _account;

  void open(LlmProviderConfig config) {
    final was = _account;
    // The same program and folder keeps a sign-in under way: the form asks
    // again on every keystroke.
    if (was != null &&
        was.cli.config.api == config.api &&
        was.cli.config.id == config.id) {
      _send();
      return;
    }
    close();
    final account = _account = CliAccount(_container, config)
      ..addListener(_send);
    unawaited(account.check());
  }

  void act(CliAccountOp op) {
    final account = _account;
    if (account == null) return;
    switch (op) {
      case CliAccountOp.signIn:
        unawaited(account.signIn());
      case CliAccountOp.signInAgain:
        unawaited(account.signIn(again: true));
      case CliAccountOp.cancel:
        unawaited(account.cancel());
    }
  }

  void answer(String code) => _account?.answer(code);

  void close() {
    _account?.dispose();
    _account = null;
  }

  void _send() {
    final account = _account;
    if (account == null) return;
    final data = switch (account.stage) {
      CliChecking() => _data(account, CliAccountStep.checking),
      CliSignedIn() => _data(account, CliAccountStep.signedIn),
      CliSignedOut() => _data(account, CliAccountStep.signedOut),
      CliInstalling(:final progress) => _data(
        account,
        CliAccountStep.installing,
        progress: progress?.bar,
      ),
      CliStarting() => _data(account, CliAccountStep.starting),
      CliWaiting(:final page) => _data(
        account,
        CliAccountStep.waiting,
        page: "$page",
      ),
      CliFailed(:final reason) => _data(
        account,
        CliAccountStep.failed,
        failure: reason,
      ),
    };
    _native.cliAccount(data).catchError((Object e) {
      logFailure("settings", "sending the program's account", e);
    });
  }

  static CliAccountData _data(
    CliAccount account,
    CliAccountStep step, {
    double? progress,
    String? page,
    String? failure,
  }) => CliAccountData(
    step: step,
    plan: account.plan,
    program: account.cli.config.displayName,
    progress: progress,
    page: page,
    failure: failure,
  );
}
