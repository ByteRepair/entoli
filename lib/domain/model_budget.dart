import "dart:math";

import "local_model.dart";

/// How much of this device a downloaded model may take, measured rather than
/// looked up: a list of devices and what each can run is a list to keep, and
/// the device can say for itself. What it decides is which catalog entries are
/// offered — a model that would not run smoothly here is not one to download.
/// One already downloaded is kept and run as before; only the offer narrows.
///
/// The measure differs by platform, because what runs out first does:
///
/// - **Apple's GPU is the model's and the window's at once.** MLX runs on
///   Metal, which says how much it can keep resident before it starts paging
///   (`recommendedMaxWorkingSetSize`), and the app draws its frames on the
///   same GPU. A Mac gets three quarters of that.
/// - **An iPhone's binding limit is the app's own.** iOS ends an app that
///   grows past what it was allowed, whatever the phone has, so what the OS
///   still lets this process grow by is measured too. A phone gets three fifths
///   of the smaller of the two — less than a Mac's share, since the UI it
///   draws beside the model is what the user feels, and slowing it would make
///   the whole phone feel sluggish. On an 8 GB phone that is the 2B and no
///   larger.
/// - **llama.cpp on Android and Linux is bounded by memory.** It reads the
///   weights into RAM whichever device runs them, and a phone shares that RAM
///   with everything else it is doing, so three fifths of it.
class ModelBudget {
  const ModelBudget(this.bytes);

  /// No measure, which offers everything: a device that would not say is not
  /// one to second-guess.
  const ModelBudget.unknown() : bytes = null;

  /// A Mac: three quarters of [workingSet], Metal's own answer for what it
  /// can keep resident.
  factory ModelBudget.mac(int workingSet) => ModelBudget(workingSet * 3 ~/ 4);

  /// An iPhone or iPad: three fifths of the smaller of Metal's [workingSet]
  /// and [available], what the OS still lets this process grow by — the
  /// limit that binds there.
  factory ModelBudget.phone({
    required int workingSet,
    required int available,
  }) => ModelBudget(min(workingSet, available) * 3 ~/ 5);

  /// Out of [total] bytes of RAM.
  factory ModelBudget.memory(int total) => ModelBudget(total * 3 ~/ 5);

  /// Null where nothing was measured.
  final int? bytes;

  /// What [model] holds while it is loaded: its weights, and the KV cache each
  /// loaded model is allowed ([kvBudgetBytes]).
  static int footprintOf(LocalModel model) =>
      (model.bytes ?? 0) + kvBudgetBytes;

  /// Whether [model] runs here. A model whose size is not known is offered,
  /// since there is nothing to hold it to.
  bool fits(LocalModel model) {
    final budget = bytes;
    if (budget == null || model.bytes == null) return true;
    return footprintOf(model) <= budget;
  }
}
