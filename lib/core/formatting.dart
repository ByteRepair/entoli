/// A size as the workspace explorer shows it, and as the backup section says
/// how big one came out. Rounded hard on purpose: it is there to tell an empty
/// file from a big one, not to be added up.
String formatSize(int bytes) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final rounded = unit == 0 || size >= 10
      ? size.round().toString()
      : size.toStringAsFixed(1);
  return "$rounded ${units[unit]}";
}

/// "200K", "1M": a window as providers write it.
String tokenCount(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    return "${m == m.roundToDouble() ? m.round() : m.toStringAsFixed(1)}M";
  }
  return n >= 1000 ? "${(n / 1000).round()}K" : "$n";
}
