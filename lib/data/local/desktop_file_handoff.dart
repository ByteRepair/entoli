import "package:url_launcher/url_launcher.dart";

import "../../domain/file_handoff.dart";

/// A desktop, which needs almost none of this port. It has a registry of
/// viewers and a file manager, so opening a file and showing its folder are the
/// same call twice — and it needs no chooser and no share sheet, because the
/// file manager this opens is already pointed at the workspace.
///
/// `url_launcher` rather than `xdg-open`/`open`/`explorer` by hand: it is
/// already a dependency and already how `PlatformLinkOpener` leaves the app,
/// and per-OS binary names are a kind of knowledge this codebase keeps in
/// plugins.
class DesktopFileHandoff implements FileHandoff {
  const DesktopFileHandoff();

  @override
  bool get canReveal => true;

  @override
  bool get canShare => false;

  @override
  Future<void> open(String path) => _launch(path);

  @override
  Future<void> reveal(String dir) => _launch(dir);

  @override
  Future<void> export(List<String> paths) async {}

  @override
  Future<List<IncomingFile>> takeShare() async => const [];

  @override
  Stream<void> get shareArrived => const Stream.empty();

  Future<void> _launch(String path) async {
    await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
  }
}
