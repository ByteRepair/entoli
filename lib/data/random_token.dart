import "dart:convert";
import "dart:math";

final _random = Random.secure();

/// [bytes] of secure randomness, base64url-encoded: a key, a nonce, a name
/// nobody else can guess.
String randomToken(int bytes) =>
    base64Url.encode(List.generate(bytes, (_) => _random.nextInt(256)));
