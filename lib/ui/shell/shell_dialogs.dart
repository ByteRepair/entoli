import "package:entoli_glass/entoli_glass.dart";

import "../widgets/dialogs.dart";

/// The app's dialogs as the platform's own alerts, over the window: what
/// `dialogs.dart`'s helpers ask while the shell is up.
class ShellDialogs implements NativeDialogs {
  ShellDialogs([NativeShell? shell]) : _shell = shell ?? NativeShell();

  final NativeShell _shell;

  Future<DialogAnswer> _ask(DialogRequest request) =>
      _shell.dialog(request).catchError((Object _) => DialogAnswer());

  @override
  Future<int?> choose(String title, List<String> choices, {int? picked}) async {
    final answer = await _ask(
      DialogRequest(
        kind: DialogKind.choice,
        title: title,
        choices: choices,
        picked: picked,
      ),
    );
    return answer.agreed ? answer.choice : null;
  }

  @override
  Future<String?> text({
    required String title,
    required String initial,
    required String confirmLabel,
    String? hint,
    String? helper,
    int lines = 1,
    bool allowBlank = false,
  }) async {
    final answer = await _ask(
      DialogRequest(
        kind: DialogKind.text,
        title: title,
        message: helper,
        confirmLabel: confirmLabel,
        initial: initial,
        hint: hint,
        lines: lines,
        allowBlank: allowBlank,
      ),
    );
    final text = answer.text?.trim() ?? "";
    if (!answer.agreed || (text.isEmpty && !allowBlank)) return null;
    return text;
  }

  @override
  Future<({String name, String value})?> pair({
    required String title,
    required String nameLabel,
    required String valueLabel,
    String name = "",
    String value = "",
  }) async {
    final answer = await _ask(
      DialogRequest(
        kind: DialogKind.pair,
        title: title,
        confirmLabel: "Save",
        label: nameLabel,
        initial: name,
        secondLabel: valueLabel,
        secondInitial: value,
      ),
    );
    final key = answer.text?.trim() ?? "";
    if (!answer.agreed || key.isEmpty) return null;
    return (name: key, value: answer.second?.trim() ?? "");
  }

  @override
  Future<void> tell({required String title, required String message}) => _ask(
    DialogRequest(kind: DialogKind.tell, title: title, message: message),
  );

  @override
  Future<bool> confirm({
    required String title,
    required String message,
    String? confirmLabel,
    String? cancelLabel,
    bool destructive = false,
  }) async => (await _ask(
    DialogRequest(
      kind: DialogKind.confirm,
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      destructive: destructive,
    ),
  )).agreed;
}
