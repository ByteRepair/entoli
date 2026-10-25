/// What an environment does with the sandbox half of the permission policy.
/// The policy — the rules, their "What it can write to", the Landlock switch —
/// is set globally and per project whatever runs the commands; the
/// environment enforces it or declares that it does not, and the Terminal page
/// says which while one is being picked. The rules' approval half is the
/// app's own gate and holds everywhere.
enum Confinement {
  /// Linux's host shell under the Landlock helper: the policy is enforced.
  landlock(
    label: "sandbox enforced",
    summary: "Enforces your sandbox settings with Landlock: commands can "
        "write only to the workspaces and the folders your rules and "
        "writable directories grant. Reading is never blocked.",
  ),

  /// A phone's host shell, inside the app's own OS sandbox.
  appSandbox(
    label: "sandbox not enforced",
    summary: "Your sandbox settings are kept but not enforced here. Commands "
        "stay inside the system's app sandbox, which reaches the app's own "
        "files and nothing else on the device. Approval rules still apply.",
  ),

  /// A downloaded Linux, under proot or the iOS emulator.
  guest(
    label: "sandbox not enforced",
    summary: "Your sandbox settings are kept but not enforced here. Commands "
        "run inside the downloaded Linux and see its files and the "
        "workspaces, not the rest of the device. Approval rules still apply.",
  ),

  /// A desktop host shell with no sandbox: macOS and Windows.
  none(
    label: "sandbox not enforced",
    summary: "Your sandbox settings are kept but not enforced here: nothing "
        "on this platform implements them. Commands run with your full user "
        "permissions and can write anywhere you can. Only the approval rules "
        "stand between the agent and your files.",
  );

  const Confinement({required this.label, required this.summary});

  /// A few words for beside the environment's name.
  final String label;

  /// What it means for a command, in a sentence or two.
  final String summary;

  /// Whether the sandbox half of the permission policy is enforced here.
  bool get enforcesSandbox => this == Confinement.landlock;
}
