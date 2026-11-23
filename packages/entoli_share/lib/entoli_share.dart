import "dart:io" show Platform;
import "dart:ui" show Rect;

import "package:entoli_core/model/share_sheet.dart";
import "package:share_plus/share_plus.dart";

/// `share_plus`'s sheet. Linux's opens a `mailto:`, which a 100K link does
/// not survive, so there it declines.
class PluginShareSheet implements ShareSheet {
  const PluginShareSheet();

  @override
  Future<bool> shareLink(Uri link, {Rect? origin}) async {
    if (Platform.isLinux) return false;
    await SharePlus.instance.share(
      ShareParams(uri: link, sharePositionOrigin: origin),
    );
    return true;
  }
}
