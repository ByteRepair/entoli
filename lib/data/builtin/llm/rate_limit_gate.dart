import "dart:async";

/// Bounds in-flight [LlmClient.stream] calls across a turn and coordinates
/// 429 backoff so a fan-out of sub-agents doesn't each-retry-into the same
/// rate limit.
///
/// One gate is shared by the parent [BuiltinAgent] and every sub-agent it
/// spawns, built per turn in `BuiltinBackend.sendPrompt`. A request acquires
/// a concurrency slot (capped at [maxConcurrent]) and waits out any active
/// cooldown before it starts. When a 429 is observed, [onRateLimited] advances
/// the shared cooldown; every other in-flight or queued request honours it via
/// [awaitReady]. Backoff grows across successive 429 episodes and resets on
/// any successful request. A wall-clock budget ([maxRetryBudget]) caps how
/// long 429 retries continue before the agent gives up; other retryables
/// keep the per-agent [BuiltinOptions.maxAttempts] path.
class RateLimitGate {
  RateLimitGate({
    required this.maxConcurrent,
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 60),
    this.maxRetryBudget = const Duration(minutes: 5),
  });

  /// How many [LlmClient.stream] calls may be in flight at once.
  final int maxConcurrent;

  final Duration initialBackoff;
  final Duration maxBackoff;
  final Duration maxRetryBudget;

  // Concurrency slot pool, mirroring the one in builtin_agent._executeTasks.
  final List<Completer<void>> _slots = [];
  int _inFlight = 0;

  // Shared cooldown.
  DateTime? _pausedUntil;
  int _episode = 0;
  DateTime? _firstRateLimitAt;

  /// Acquire a concurrency slot, waiting first for any active cooldown.
  Future<void> acquire() async {
    await awaitReady();
    if (_inFlight >= maxConcurrent) {
      final completer = Completer<void>();
      _slots.add(completer);
      await completer.future;
    }
    _inFlight++;
  }

  /// Release a concurrency slot, waking one queued acquirer if any.
  void release() {
    if (_inFlight > 0) _inFlight--;
    if (_slots.isNotEmpty) _slots.removeAt(0).complete();
  }

  /// Block until the cooldown has expired. Returns immediately when not paused.
  Future<void> awaitReady() async {
    while (true) {
      final until = _pausedUntil;
      if (until == null) return;
      final remaining = until.difference(DateTime.now());
      if (remaining.isNegative || remaining == Duration.zero) return;
      await Future<void>.delayed(remaining);
    }
  }

  /// Record a 429. Returns the pause to wait out. A 429 that lands during an
  /// active pause does not advance the backoff — eight concurrent 429s are one
  /// episode, not eight.
  Duration onRateLimited() {
    final now = DateTime.now();
    _firstRateLimitAt ??= now;
    final alreadyPaused = _pausedUntil != null && now.isBefore(_pausedUntil!);
    if (alreadyPaused) return _pausedUntil!.difference(now);
    _episode++;
    final ms = initialBackoff.inMilliseconds * (1 << (_episode - 1));
    final backoff = Duration(milliseconds: ms > maxBackoff.inMilliseconds
        ? maxBackoff.inMilliseconds
        : ms);
    _pausedUntil = now.add(backoff);
    return backoff;
  }

  /// Whether the 429 retry budget is spent. The agent checks this before
  /// retrying a 429; non-429 retryables are governed by `maxAttempts`.
  bool retryBudgetExhausted() {
    final first = _firstRateLimitAt;
    if (first == null) return false;
    return DateTime.now().difference(first) > maxRetryBudget;
  }

  /// Reset the backoff and cooldown. Called after any successful request —
  /// the provider served one, so the rate limit has cleared.
  void onSuccess() {
    _episode = 0;
    _pausedUntil = null;
    _firstRateLimitAt = null;
  }
}