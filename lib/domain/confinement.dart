/// What an environment does with the sandbox half of the permission policy.
/// The policy — the rules, their "What it can write to", the sandbox switch —
/// is set globally and per project whatever runs the commands; the
/// environment enforces it or it does not, and the Terminal page's status
/// card says which. The rules' approval half is the app's own gate and holds
/// everywhere.
enum Confinement {
  /// Linux's host shell under the Landlock helper.
  landlock,

  /// macOS's host shell under `sandbox-exec`.
  seatbelt,

  /// A phone's host shell, inside the app's own OS sandbox.
  appSandbox,

  /// A downloaded Linux, under proot or the iOS emulator.
  guest,

  /// A desktop host shell with no sandbox: Windows.
  none;

  /// Whether the sandbox half of the permission policy is enforced here.
  bool get enforcesSandbox =>
      this == Confinement.landlock || this == Confinement.seatbelt;
}
