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

  /// What a bar shows: [fraction], and indeterminate while it unpacks, which
  /// reports no count of its own.
  double? get bar => unpacking ? null : fraction;
}

/// A download as the code doing it sees it: files fetched to disk, progress
/// reported, and [cancelled] checked wherever it would carry on doing work
/// nobody is waiting for. The app's `DownloadRun` is the one there is; a
/// store outside the app is handed a [StartDownload] that makes one.
abstract interface class DownloadTask {
  /// Whether the listener has gone.
  bool get cancelled;

  void report(DownloadProgress progress);

  /// One file, streamed to [to], and how many bytes it turned out to be.
  /// [done] is what earlier files already added up to and [total] what they
  /// will in the end, so several files report one bar.
  Future<int> fetch({
    required String url,
    required String to,
    int? total,
    int done = 0,
  });
}

/// Starts a download whose [run] does the fetching, and whose [discard] undoes
/// a half-done one when the listener leaves or [run] throws.
typedef StartDownload =
    Stream<DownloadProgress> Function({
      required Future<void> Function(DownloadTask task) run,
      required Future<void> Function() discard,
    });
