// The TLS fallback's mechanics against fakes. The certificate-verify refusal
// is the one reason a handshake may be tried again under the bundled set;
// every other keeps its error; the platform gate is a flag; and the clients'
// calls and their closure are what count. The bundled set's own client is
// injected: a test has no store to read and wants the mechanics, not a real
// socket.
import "dart:io";

import "package:flutter_test/flutter_test.dart";
import "package:http/http.dart" as http;

import "package:agent_chat/core/tls/trust_io.dart";

http.StreamedResponse _answered(String body) => http.StreamedResponse(
      http.ByteStream.fromBytes([body.codeUnitAt(0)]),
      200,
    );

class _AnswerClient extends http.BaseClient {
  final String body;
  int sent = 0;
  int closed = 0;

  _AnswerClient(this.body);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent += 1;
    return _answered(body);
  }

  @override
  void close() {
    closed += 1;
  }
}

class _RefusingClient extends http.BaseClient {
  final String refusal;
  int sent = 0;
  int closed = 0;

  _RefusingClient({this.refusal = "CERTIFICATE_VERIFY_FAILED: no root there"});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent += 1;
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

  test("a fallback that refuses too leaves the original error standing",
      () async {
    final client = TlsFallbackClient(_RefusingClient(),
        windows: true, fallback: _RefusingClient());

    await expectLater(
        client.send(_request()), throwsA(isA<HandshakeException>()));
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