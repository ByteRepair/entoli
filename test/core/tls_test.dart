// The TLS fallback's mechanics against fakes. The certificate-verify refusal
// is the one reason a handshake may be tried again under the bundled set;
// every other keeps its error; the platform gate is a flag; and the clients'
// calls and their closure are what count. The bundled set's own client is
// injected: a test has no store to read and wants the mechanics, not a real
// socket.
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;

import "package:agent_chat/core/tls.dart";

http.StreamedResponse _answered(String body) => http.StreamedResponse(
      http.ByteStream.fromBytes([body.codeUnitAt(0)]),
      200,
    );

class _AnswerClient extends http.BaseClient {
  final String body;

  /// A real IOClient finalizes its request before it opens the socket —
  /// where the TLS handshake dies — so a fake playing one has to do the
  /// same before it answers, or the retry's state is not the production one.
  final bool finalizeRequest;
  int sent = 0;
  int closed = 0;

  _AnswerClient(this.body, {this.finalizeRequest = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent += 1;
    if (finalizeRequest) request.finalize();
    return _answered(body);
  }

  @override
  void close() {
    closed += 1;
  }
}

class _RefusingClient extends http.BaseClient {
  final String refusal;
  final bool finalizeRequest;
  int sent = 0;
  int closed = 0;

  _RefusingClient(
      {this.refusal = "CERTIFICATE_VERIFY_FAILED: no root there",
      this.finalizeRequest = false});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent += 1;
    if (finalizeRequest) request.finalize();
    throw HandshakeException(
        "Handshake error in client (OS Error:\n\t$refusal)");
  }

  @override
  void close() {
    closed += 1;
  }
}

http.Request _request() => http.Request("GET", Uri.parse("https://a.host/x"));

void main() {
  test("a certificate-verify refusal is retried under the bundled set", () async {
    final moz = _AnswerClient("m");
    final client = TlsFallbackClient(_RefusingClient(),
        windows: true, fallback: moz);

    final response = await client.send(_request());
    expect(await response.stream.bytesToString(), "m");
    expect(moz.sent, 1);
  });

  test("a handshake that failed for any other reason is not retried", () async {
    final primary = _RefusingClient(refusal: "WRONG_VERSION_NUMBER: no");
    final client = TlsFallbackClient(primary, windows: true);

    await expectLater(
        client.send(_request()),
        throwsA(predicate((e) =>
            e is HandshakeException && "$e".contains("WRONG_VERSION_NUMBER"))));
    expect(primary.sent, 1);
  });

  test("nowhere but Windows is the fallback even tried", () async {
    final primary = _RefusingClient();
    final client = TlsFallbackClient(primary, windows: false);

    await expectLater(
        client.send(_request()), throwsA(isA<HandshakeException>()));
    expect(primary.sent, 1);
  });

  test("the fallback's first answer makes it the client after", () async {
    final system = _RefusingClient();
    final moz = _AnswerClient("m");
    final client = TlsFallbackClient(system,
        windows: true, fallback: moz);

    await client.send(_request());
    await client.send(_request());
    // The system's trust was asked once, the second request went straight to
    // the client that had answered.
    expect(system.sent, 1);
    expect(moz.sent, 2);
  });

  test("the re-send is a fresh request the fallback may finalize", () async {
    final client = TlsFallbackClient(_RefusingClient(finalizeRequest: true),
        windows: true,
        fallback: _AnswerClient("m", finalizeRequest: true));

    final response = await client.send(_request()..body = "hello");
    expect(await response.stream.bytesToString(), "m");
    client.close();
  });

  test("the pin is the refusing host's, not the wrapper's", () async {
    final system = _RefusingClient();
    final moz = _AnswerClient("m");
    final client = TlsFallbackClient(system, windows: true, fallback: moz);

    await client.send(http.Request("GET", Uri.parse("https://a.host/x")));
    await client.send(http.Request("GET", Uri.parse("https://other.host/x")));
    // The first host is pinned; the other still asks the system's store,
    // refuses there, and earns its own retry under the bundled set.
    expect(system.sent, 2);
    expect(moz.sent, 2);
    client.close();
  });

  test("a fallback that refuses too leaves the original error standing",
      () async {
    final client = TlsFallbackClient(_RefusingClient(),
        windows: true,
        fallback: _RefusingClient(
            refusal: "CERTIFICATE_VERIFY_FAILED: bundled too"));

    try {
      await client.send(_request());
      fail("the request did not throw");
    } on HandshakeException catch (e) {
      // The primary's refusal, not the fallback's own and not the StateError
      // a finalize that cannot run again would have raised.
      expect("$e", contains("no root there"));
    }
    client.close();
  });

  test("closing closes both clients", () async {
    final system = _RefusingClient();
    final moz = _AnswerClient("m");
    final client = TlsFallbackClient(system,
        windows: true, fallback: moz);

    await client.send(_request());
    client.close();
    expect(system.closed, 1);
    expect(moz.closed, 1);
  });
}