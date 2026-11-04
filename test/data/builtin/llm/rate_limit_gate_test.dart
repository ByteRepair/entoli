import "package:fake_async/fake_async.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/rate_limit_gate.dart";

/// The cooldown and the retry budget are measured against `clock`, which
/// `fakeAsync` swaps for its own, so every pause here is elapsed by hand
/// rather than waited out.
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
        // Hold the slot across a turn of the event loop so the others pile up.
        await Future<void>.delayed(Duration.zero);
        inFlight--;
        gate.release();
      }

      await Future.wait(List.generate(10, (_) => task()));
      expect(maxSeen, 3);
      expect(inFlight, 0);
    });

    test(
      "a fresh acquire cannot take the slot a release hands a waiter",
      () async {
        final gate = RateLimitGate(maxConcurrent: 1);
        var holding = 0;
        var maxSeen = 0;
        Future<void> hold(Future<void> acquired) async {
          await acquired;
          holding++;
          if (holding > maxSeen) maxSeen = holding;
        }

        await gate.acquire();
        holding = 1;
        final waiter = hold(gate.acquire());
        await Future<void>.delayed(Duration.zero);

        // The fresh acquire is still in its cooldown check when the release
        // lands, so it reaches the count before the woken waiter does.
        final fresh = hold(gate.acquire());
        holding--;
        gate.release();
        await Future<void>.delayed(Duration.zero);

        expect(maxSeen, 1);
        expect(holding, 1);
        holding--;
        gate.release();
        await Future.wait([waiter, fresh]);
        expect(maxSeen, 1);
      },
    );
  });

  group("RateLimitGate cooldown", () {
    test("onRateLimited sets a pause awaitReady waits out", () {
      fakeAsync((async) {
        final gate = RateLimitGate(
          maxConcurrent: 4,
          initialBackoff: const Duration(milliseconds: 100),
        );
        gate.onRateLimited();
        var returned = false;
        gate.awaitReady().then((_) => returned = true);

        async.elapse(const Duration(milliseconds: 99));
        expect(returned, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(returned, isTrue);
      });
    });

    test("backoff grows across episodes and caps at maxBackoff", () {
      fakeAsync((async) {
        final gate = RateLimitGate(
          maxConcurrent: 4,
          initialBackoff: const Duration(milliseconds: 50),
          maxBackoff: const Duration(milliseconds: 400),
        );
        final pauses = <int>[];
        for (var i = 0; i < 5; i++) {
          final pause = gate.onRateLimited();
          pauses.add(pause.inMilliseconds);
          async.elapse(pause);
        }
        expect(pauses, [50, 100, 200, 400, 400]);
      });
    });

    test("a 429 during an active pause does not advance the backoff", () {
      fakeAsync((async) {
        final gate = RateLimitGate(
          maxConcurrent: 4,
          initialBackoff: const Duration(milliseconds: 500),
        );
        expect(gate.onRateLimited().inMilliseconds, 500);
        async.elapse(const Duration(milliseconds: 200));
        // The same episode: what is left of it, not a doubled pause.
        expect(gate.onRateLimited().inMilliseconds, 300);
        async.elapse(const Duration(milliseconds: 300));
        expect(gate.onRateLimited().inMilliseconds, 1000);
      });
    });

    test("onSuccess resets the cooldown", () {
      fakeAsync((async) {
        final gate = RateLimitGate(
          maxConcurrent: 4,
          initialBackoff: const Duration(milliseconds: 50),
        );
        gate.onRateLimited();
        gate.onSuccess();
        var returned = false;
        gate.awaitReady().then((_) => returned = true);
        async.flushMicrotasks();
        expect(returned, isTrue);
        // And the next episode starts from the bottom again.
        expect(gate.onRateLimited().inMilliseconds, 50);
      });
    });
  });

  group("RateLimitGate retry budget", () {
    test("is spent once the budget has passed since the first 429", () {
      fakeAsync((async) {
        final gate = RateLimitGate(
          maxConcurrent: 4,
          maxRetryBudget: const Duration(milliseconds: 80),
        );
        gate.onRateLimited();
        async.elapse(const Duration(milliseconds: 80));
        expect(gate.retryBudgetExhausted(), isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(gate.retryBudgetExhausted(), isTrue);

        gate.onSuccess();
        expect(gate.retryBudgetExhausted(), isFalse);
      });
    });
  });
}
