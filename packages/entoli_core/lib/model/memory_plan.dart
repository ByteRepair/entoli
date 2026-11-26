import "dart:math";

/// How much conversation a loaded model has room for, and what that room is
/// made of. Each runtime answers it for its own models (`LocalRuntime.plan`),
/// and its [contextLength] is the model's window wherever one is read: the
/// auto-compact threshold, the context page, and the runtime's own refusal of
/// a prompt past it.
abstract class MemoryPlan {
  const MemoryPlan();

  /// The most tokens of conversation the model is run with.
  int get contextLength;

  /// Why the model cannot be run under this plan, or null where it can.
  String? get refusal => null;

  /// The context where the model runs under this plan, or null where it
  /// does not: a window of nothing is no answer.
  int? get window => refusal == null ? contextLength : null;

  /// What decides whether a loaded model is still the one asked for: a model
  /// loaded under another plan is loaded again.
  Object get identity => contextLength;
}

/// A context fixed at load: llama.cpp sizes its KV cache when the server
/// starts, from the setting or the model's own default.
class FixedContextPlan extends MemoryPlan {
  const FixedContextPlan(this.contextLength);

  @override
  final int contextLength;
}

/// No budget to plan against: the model gets what it was trained on and its
/// runtime's own defaults, or, where a budget is what keeps the app alive and
/// none could be had, is refused with [refusal].
class UnplannedMemory extends MemoryPlan {
  const UnplannedMemory(this.contextLength, {this.refusal});

  @override
  final int contextLength;

  @override
  final String? refusal;
}

/// What a model's architecture costs in memory, read off its own config.
class ModelShape {
  const ModelShape({
    required this.weightBytes,
    required this.kvBytesPerToken,
    required this.trainedContext,
    this.stateBytes = 0,
    this.attentionLayers = 0,
    this.attentionHeads = 0,
    this.headDim = 0,
    this.hiddenSize = 0,
    this.intermediateSize = 0,
  });

  final int weightBytes;

  /// K and V for every layer with attention, per token of conversation.
  final int kvBytesPerToken;

  final int trainedContext;

  /// What stays the same size whatever the conversation: a hybrid's
  /// linear-attention layers keep one recurrent state each.
  final int stateBytes;

  final int attentionLayers;
  final int attentionHeads;
  final int headDim;
  final int hiddenSize;
  final int intermediateSize;

  /// Whether MLX's attention writes out the whole score matrix for a prefill
  /// chunk. Its fused kernel is skipped for 192- and 256-wide heads once a
  /// chunk is past 8 tokens (`use_fallback` in mlx's
  /// `scaled_dot_product_attention.cpp`), and the unfused path holds the
  /// scores and their softmax, both f16.
  bool get scoresWrittenOut => headDim == 192 || headDim == 256;

  /// The working memory one token of a prefill chunk takes, against a
  /// conversation of [context] tokens: the attention scores where they are
  /// written out, one layer at a time, and the MLP's three activations, f16.
  int scratchPerToken(int context) =>
      (scoresWrittenOut ? 2 * 2 * attentionHeads * context : 0) +
      2 * (3 * intermediateSize + 4 * hiddenSize);
}

/// Everything MLX does inside one budget, so the rest of the app keeps what
/// the budget leaves it: the weights, the fixed state, the prefill's working
/// memory, MLX's buffer cache, and the KV cache, which gets what is left and
/// so decides the context.
///
/// The prefill's working memory grows with the conversation where the scores
/// are written out, so it is held to [scratchBytes] by the step size rather
/// than allowed for: [prefillStep] is the longest chunk whose scratch fits at
/// the full [contextLength].
class BudgetPlan extends MemoryPlan {
  BudgetPlan(this.shape, {required this.budgetBytes, this.sharedBy = 1});

  final ModelShape shape;

  /// What this model may take, all of it.
  final int budgetBytes;

  /// How many models the device's budget was split between, for a refusal
  /// that says why the share is what it is.
  final int sharedBy;

  /// The prefill's working memory, whatever the conversation's length.
  static const scratchBytes = 256 << 20;

  /// What MLX keeps of the buffers it frees, for the next allocation. Small:
  /// a kept buffer is memory the app is not using.
  static const cacheBytes = 64 << 20;

  /// The shortest context a model is worth running with: an agent's own
  /// instructions and tools take a few thousand tokens before anything is
  /// said.
  static const minimumContext = 4096;

  /// What is left for the KV cache once everything else is counted.
  int get kvBytes =>
      budgetBytes -
      shape.weightBytes -
      shape.stateBytes -
      scratchBytes -
      cacheBytes;

  /// A model with no per-token cache is held to what it was trained on.
  @override
  int get contextLength => shape.kvBytesPerToken <= 0
      ? (kvBytes >= 0 ? shape.trainedContext : 0)
      : max(0, min(shape.trainedContext, kvBytes ~/ shape.kvBytesPerToken));

  /// Between 16 and mlx-swift-lm's own default of 512.
  int get prefillStep {
    final perToken = shape.scratchPerToken(contextLength);
    return perToken <= 0 ? 512 : (scratchBytes ~/ perToken).clamp(16, 512);
  }

  @override
  Object get identity => (budgetBytes, contextLength, prefillStep);

  @override
  String? get refusal {
    if (contextLength >= minimumContext) return null;
    final needed =
        budgetBytes - kvBytes + minimumContext * shape.kvBytesPerToken;
    final share = sharedBy > 1
        ? "each of the $sharedBy models that may stay loaded has "
              "${_gb(budgetBytes)} here; keep fewer loaded under On-device"
        : "on-device models have ${_gb(budgetBytes)} here";
    return "it needs ${_gb(needed)} with room to talk, and $share";
  }

  static String _gb(int bytes) => "${(bytes / 1e9).toStringAsFixed(1)} GB";
}
