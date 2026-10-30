/// How a turn of the built-in agent runs: its limits, its patience, and how
/// much of it runs at once. One value for a parent and its sub-agents alike.
class BuiltinOptions {
  const BuiltinOptions({
    this.stepLimit = 40,
    this.commandTimeout = const Duration(minutes: 3),
    this.maxAttempts = 4,
    this.retryBackoff = const Duration(seconds: 1),
    this.maxConcurrentSubAgents = 8,
    this.maxConcurrentLlmRequests = 4,
    this.rateLimitRetryBudget = const Duration(minutes: 5),
  });

  /// How many model calls one turn may make. Upstream defaults to no limit and
  /// leans on a cost limit instead; a chat has someone waiting, so it counts
  /// steps.
  final int stepLimit;
  final Duration commandTimeout;

  /// How many times a failed request is tried again before the turn gives up,
  /// and the first wait between two — it doubles after that, so the defaults
  /// spend 7s waiting in total. Deliberately short for the parent: the
  /// controller carries a failed turn on itself, and one attempt here plus its
  /// retry rounds there is the same patience without a second mechanism.
  /// Sub-agents keep the default, a failed worker being a tool result the
  /// parent can redo rather than a turn to give up on. Applies to retryables
  /// other than 429; a 429 is governed by the shared [RateLimitGate] and
  /// [rateLimitRetryBudget].
  final int maxAttempts;
  final Duration retryBackoff;

  /// How many `task` calls in one message run at once. A deep-research turn
  /// can fan out to 75 sub-agents; 8 concurrent keeps provider rate limits
  /// in reach without serializing the whole batch. Bounds long-lived agent
  /// parallelism, distinct from [maxConcurrentLlmRequests] which bounds the
  /// in-flight request count — one sub-agent makes up to [stepLimit] calls.
  final int maxConcurrentSubAgents;

  /// How many [LlmClient.stream] calls may be in flight at once across the
  /// parent agent and every sub-agent it spawns. A [RateLimitGate] enforces
  /// it per turn; the gate also coordinates 429 backoff so a fan-out doesn't
  /// each-retry-into the same rate limit.
  final int maxConcurrentLlmRequests;

  /// How long 429 retries continue through the shared cooldown before the
  /// agent gives up. Other retryables (503, connection drops) keep
  /// [maxAttempts].
  final Duration rateLimitRetryBudget;

  BuiltinOptions copyWith({int? stepLimit, int? maxAttempts}) => BuiltinOptions(
    stepLimit: stepLimit ?? this.stepLimit,
    commandTimeout: commandTimeout,
    maxAttempts: maxAttempts ?? this.maxAttempts,
    retryBackoff: retryBackoff,
    maxConcurrentSubAgents: maxConcurrentSubAgents,
    maxConcurrentLlmRequests: maxConcurrentLlmRequests,
    rateLimitRetryBudget: rateLimitRetryBudget,
  );
}
