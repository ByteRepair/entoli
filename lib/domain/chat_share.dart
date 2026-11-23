import "dart:convert";
import "dart:typed_data";

/// Where a shared chat's link points: the read-only viewer
/// (packages/entoli_share_viewer), and the host the phones claim so the app
/// opens it where it is installed.
const shareHost = "share.entoli.byterepair.io";

/// The longest link Share makes. Android carries it in a Binder transaction
/// twice — into the share sheet, and into the app that opens it — each a
/// megabyte shared by everything in flight, a character two bytes there.
const shareLinkMaxLength = 128 * 1024;

/// What a share can carry besides the conversation, in the order the share
/// dialog lists them.
enum ShareSection {
  attachments,
  artifacts,
  workspace;

  /// The order sections are left out in when the link is too long: the
  /// workspace first, the attachments — what the conversation shows — last.
  static const dropOrder = [workspace, artifacts, attachments];
}

/// What the user ticked, by section: resource names, artifact ids, and paths
/// under the workspace.
typedef SharePicks = Map<ShareSection, Set<String>>;

/// How a share with some picks comes out: how long its link is, and which
/// sections are left out to bring it under [shareLinkMaxLength]. [fits] is
/// false where even the conversation alone is too long.
class ShareFit {
  const ShareFit({required this.length, required this.dropped});

  final int length;
  final Set<ShareSection> dropped;

  bool get fits => length <= shareLinkMaxLength;

  /// [picks] without what this fit leaves out: what Share packs.
  SharePicks kept(SharePicks picks) => {
    for (final MapEntry(:key, :value) in picks.entries)
      key: dropped.contains(key) ? const {} : value,
  };
}

/// How [picks] fit, given what each costs in the zip. A zip compresses each
/// member on its own, so the zip is [base] — the conversation, and the
/// directory's end — plus each kept item's [cost], exactly. Whole sections
/// go, in [ShareSection.dropOrder], until the link fits.
ShareFit shareFit({
  required int base,
  required SharePicks picks,
  required int Function(ShareSection section, String id) cost,
}) {
  int bytes(Set<ShareSection> dropped) =>
      base +
      [
        for (final MapEntry(key: section, value: ids) in picks.entries)
          if (!dropped.contains(section))
            for (final id in ids) cost(section, id),
      ].fold(0, (a, b) => a + b);
  final dropped = <ShareSection>{};
  var length = shareLinkLength(bytes(dropped));
  for (final section in ShareSection.dropOrder) {
    if (length <= shareLinkMaxLength) break;
    if (picks[section]?.isEmpty ?? true) continue;
    dropped.add(section);
    length = shareLinkLength(bytes(dropped));
  }
  return ShareFit(length: length, dropped: dropped);
}

const _linkPrefix = "https://$shareHost/#";

/// The link carrying [zip]: in the fragment, which a browser never sends to
/// the server.
String shareLinkOf(Uint8List zip) =>
    "$_linkPrefix${base64Url.encode(zip).replaceAll("=", "")}";

/// How long [shareLinkOf] comes out for a zip of [bytes]: unpadded base64.
int shareLinkLength(int bytes) => _linkPrefix.length + (bytes * 4 + 2) ~/ 3;

/// The zip a share link carries, or null where it is cut short or not one:
/// a chat app that truncates a long link hands over something that still
/// looks like one, and a zip's end record says whether all of it arrived.
Uint8List? shareZipOf(String payload) {
  try {
    final zip = base64Url.decode(base64Url.normalize(payload.trim()));
    return zipEnds(zip) ? zip : null;
  } on FormatException {
    return null;
  }
}

/// Whether [zip] ends exactly where its end-of-central-directory record says
/// it does: the record's signature, then its comment, then nothing.
bool zipEnds(Uint8List zip) {
  for (
    var at = zip.length - 22;
    at >= 0 && at >= zip.length - 22 - 0xffff;
    at--
  ) {
    if (zip[at] == 0x50 &&
        zip[at + 1] == 0x4b &&
        zip[at + 2] == 0x05 &&
        zip[at + 3] == 0x06) {
      final comment = zip[at + 20] | zip[at + 21] << 8;
      return at + 22 + comment == zip.length;
    }
  }
  return false;
}

/// Folders that are someone's credentials or a build's output, left unticked
/// in the share dialog wherever they appear in a path.
const _ignoredDirs = {
  ".git",
  ".ssh",
  ".aws",
  ".gnupg",
  ".kube",
  ".docker",
  "node_modules",
  ".venv",
  "venv",
  "__pycache__",
  ".dart_tool",
  ".gradle",
  ".idea",
  ".next",
  "build",
  "dist",
  "target",
};

/// Files that hold secrets, by name. A trailing `*` matches any suffix, a
/// leading one any prefix.
const _ignoredFiles = {
  ".env",
  ".env.*",
  ".envrc",
  ".netrc",
  ".npmrc",
  ".pypirc",
  ".git-credentials",
  ".DS_Store",
  "id_rsa*",
  "id_dsa*",
  "id_ecdsa*",
  "id_ed25519*",
  "credentials*",
  "secrets*",
  "*.pem",
  "*.key",
  "*.p12",
  "*.pfx",
  "*.keystore",
  "*.jks",
  "*.kdbx",
  "*.tfstate",
};

/// Whether the share dialog leaves [path] — `/`-separated, under the
/// workspace — unticked until the user ticks it.
bool isShareIgnored(String path) {
  final segments = path.split("/");
  if (segments.take(segments.length - 1).any(_ignoredDirs.contains)) {
    return true;
  }
  final name = segments.last.toLowerCase();
  return _ignoredFiles.any(
    (pattern) => pattern.startsWith("*")
        ? name.endsWith(pattern.substring(1))
        : pattern.endsWith("*")
        ? name.startsWith(pattern.substring(0, pattern.length - 1))
        : name == pattern,
  );
}
