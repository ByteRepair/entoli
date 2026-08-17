import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/rate_limit_gate.dart";

void main() {
  group("RateLimitGate concurrency", () {
    test("acquire/release bounds in-flight to maxConcurrent", () async {
      final gate = RateLimitGate(maxConcurrent: 3);
      var inFlight = 0;
      var maxSeen = 0;

      Future<void> task() async {
        await gate.acquire();
        inFlight++;
        if (inFlight > maxSeen) maxSeen = inFlight;
        // Hold the slot briefly so concurrent tasks pile up.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        inFlight--;
        gate.release();
      }

      await Future.wait(List.generate(10, (_) => task()));
      expect(maxSeen, lessThanOrEqualTo(3));
      expect(inFlight, 0);
    });

    test("release wakes a queued acquirer", () async {
      final gate = RateLimitGate(maxConcurrent: 1);
      await gate.acquire();
      final queued = gate.acquire();
      // Let the microtask queue drain so the queued acquire is waiting.
      await Future<void>.delayed(Duration.zero);
      gate.release();
      // The queued acquire now has a slot; release it so the test ends clean.
      await queued;
      gate.release();
    });
  });

  group("RateLimitGate cooldown", () {
    test("awaitReady returns immediately when not paused", () async {
      final gate = RateLimitGate(maxConcurrent: 4);
      await gate.awaitReady();
    });

    test("onRateLimited sets a pause awaitReady waits out", () async {
      final gate = RateLimitGate(
        maxConcurrent: 4,
        initialBackoff: const Duration(milliseconds: 100),
      );
      gate.onRateLimited();
      // A second call should block until the cooldown expires. Run it on the
      // event loop and race it against a timeout that is shorter than the
      // pause plus a margin — if awaitReady returned immediately, the future
      // resolves before the timeout.
      var returned = false;
      final ready = gate.awaitReady().then((_) => returned = true);
      // Give it a chance to return early if the gate is broken.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(returned, isFalse);
      await ready;
      expect(returned, isTrue);
    });

    test("backoff grows across episodes and caps at maxBackoff", () async {
      final gate = RateLimitGate(
        maxConcurrent: 4,
        initialBackoff: const Duration(milliseconds: 50),
        maxBackoff: const Duration(milliseconds: 400),
      );
      // Episode 1: 50ms
      var pause = gate.onRateLimited();
      expect(pause.inMilliseconds, 50);
      await gate.awaitReady();
      // Episode 2: 100ms
      pause = gate.onRateLimited();
      expect(pause.inMilliseconds, 100);
      await gate.awaitReady();
      // Episode 3: 200ms
      pause = gate.onRateLimited();
      expect(pause.inMilliseconds, 200);
      await gate.awaitReady();
      // Episode 4: 400ms (capped)
      pause = gate.onRateLimited();
      expect(pause.inMilliseconds, 400);
      await gate.awaitReady();
      // Episode 5: still 400ms (cap holds)
      pause = gate.onRateLimited();
      expect(pause.inMilliseconds, 400);
    });

    test("a 429 during an active pause does not advance the backoff", () {
      final gate = RateLimitGate(
        maxConcurrent: 4,
        initialBackoff: const Duration(milliseconds: 500),
      );
      final first = gate.onRateLimited();
      expect(first.inMilliseconds, 500);
      // A second 429 lands while the first pause is still active.
      final second = gate.onRateLimited();
      // The remaining pause is shorter than the full 500ms but the episode
      // counter did not advance — no new 1000ms or 2000ms pause was set.
      expect(second.inMilliseconds, lessThanOrEqualTo(500));
    });

    test("onSuccess resets the cooldown", () async {
      final gate = RateLimitGate(
        maxConcurrent: 4,
        initialBackoff: const Duration(milliseconds: 50),
      );
      gate.onRateLimited();
      gate.onSuccess();
      // No pause should remain.
      await gate.awaitReady();
    });
  });

  group("RateLimitGate retry budget", () {
    test("retryBudgetExhausted is false until the budget elapses", () async {
      final gate = RateLimitGate(
        maxConcurrent: 4,
        maxRetryBudget: const Duration(milliseconds: 80),
      );
      gate.onRateLimited();
      expect(gate.retryBudgetExhausted(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gate.retryBudgetExhausted(), isTrue);
    });

    test("onSuccess clears the budget marker", () async {
      final gate = RateLimitGate(
        maxConcurrent: 4,
        maxRetryBudget: const Duration(milliseconds: 80),
      );
      gate.onRateLimited();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gate.retryBudgetExhausted(), isTrue);
      gate.onSuccess();
      expect(gate.retryBudgetExhausted(), isFalse);
    });
  });
}