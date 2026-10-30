/// How far along a download is. One value for both catalogs — the voice models
/// and the Linux the agent runs commands in — because it was the same three
/// fields twice, and a bar reading one of them cannot tell which store filled
/// it in.
///
/// [unpacking] is the second phase, and the reason this is not a pair of ints:
/// a speech model is a `.tar.bz2` that Dart decodes at about 8 MB/s, and a
/// rootfs is thousands of small files a phone writes slowly. A bar sitting at
/// 100% through either reads as a hang.
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    required this.total,
    this.unpacking = false,
  });

  final int received;
  final int total;
  final bool unpacking;

  /// 0 to 1, or null where there is nothing to divide by — the bar goes
  /// indeterminate rather than guessing.
  double? get fraction =>
      total <= 0 ? null : (received / total).clamp(0.0, 1.0);
}
