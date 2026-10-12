import "dart:async";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;

import "fake_network.dart";

/// The store tests stand cancelled downloads on this seam, and the one
/// promise a cancellation leans on is that closing the client ends the
/// response where it got to — whenever it next waits on the hold, not only
/// when it was already there as the close landed. The other order was a
/// deadlock: the close found nothing registered to abandon, the response
/// then parked in the hold behind a request nobody would release, and the
/// cancelled download's `cancel()` never came back.
void main() {
  test("a response reaching its hold after the client is closed ends there", () async {
    final net = FakeNetwork.inHalves({"/f": List.filled(64, 1)});
    net.hold = Completer<void>();
    final response = await net.send(http.Request("GET", Uri.parse("${FakeNetwork.host}/f")));

    // Paused before the first of the two halves is even delivered, so the
    // generator is parked on the yield — never yet at the hold — while the
    // client closes. Resuming is what reaches the hold.
    final done = Completer<void>();
    final received = <int>[];
    final sub = response.stream.listen(received.addAll, onDone: done.complete);
    sub.pause();
    net.close();
    sub.resume();
    await done.future;

    expect(received, List.filled(32, 1));
  });
}