import "dart:convert";
import "dart:typed_data";

/// The longest link Entoli makes, the same everywhere so a link opens on any
/// machine it is sent to. Windows sets it: a link reaches the app as an
/// argument, and a command line there is 32,767 characters, the quoted exe
/// path included.
const appLinkMaxLength = 32000;

/// [bytes] as a link carries them: base64url, unpadded.
String encodeLinkBytes(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll("=", "");

/// How long [encodeLinkBytes] comes out for [bytes] bytes.
int encodedLinkLength(int bytes) => (bytes * 4 + 2) ~/ 3;

/// The inverse of [encodeLinkBytes], padded or not. Throws a
/// [FormatException] where [text] is not base64url.
Uint8List decodeLinkBytes(String text) =>
    base64Url.decode(base64Url.normalize(text.trim()));
