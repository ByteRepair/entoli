import "../../core/log.dart";
import "../../core/platform/artifact_server.dart";
import "../settings/controller.dart";
import "../settings/spec.dart";
import "app_page.dart";

/// A web page opened in the app rather than in the browser.
class WebAppPage extends AppPage {
  WebAppPage(this.url, {this.label});

  final Uri url;
  final String? label;

  /// Where the view is now, and what that page calls itself.
  late Uri _at = url;
  String? _title;

  @override
  String get address => "web/$url";

  @override
  String title(SettingReader reader) => label ?? _title ?? _at.host;

  @override
  List<PageSection> sections(SettingReader reader) => [
    PageSection("page", "", [
      WebController(
        part("page", ""),
        url: url,
        onNavigated: (at, title) {
          final named = (title?.isEmpty ?? true) ? null : title;
          if (at == _at && named == _title) return;
          _at = at;
          _title = named;
          changed();
        },
      ),
    ]),
  ];

  @override
  List<ActionController> toolbar(SettingReader reader) => [
    ActionController(
      part("copy", "Copy Link"),
      label: "Copy Link",
      run: () async => SettingNotice("Copied link", copy: "$_at"),
    ),
  ];
}

/// An artifact on a phone: its directory served on loopback for the time
/// the page is open, so its relative references resolve, and the entry file
/// shown from there. See "Artifacts" in the root notes.
class ArtifactAppPage extends AppPage {
  ArtifactAppPage({required this.dir, required this.entryFile, this.label});

  final String dir;
  final String entryFile;
  final String? label;

  ArtifactServer? _server;
  String? _error;

  @override
  String get address => "artifact/$dir/$entryFile";

  @override
  void opened() => _start();

  Future<void> _start() async {
    try {
      _server = await ArtifactServer.start(dir);
    } catch (e) {
      logFailure("artifact", "could not serve $dir", e);
      _error = "Failed to open the artifact: $e";
    }
    changed();
  }

  @override
  void closed() => _server?.stop();

  @override
  String title(SettingReader reader) => label ?? "Artifact";

  @override
  List<PageSection> sections(SettingReader reader) {
    final server = _server;
    return [
      PageSection("page", "", [
        if (server != null)
          WebController(
            part("page", ""),
            url: Uri.parse("${server.baseUrl}/$entryFile"),
          )
        else
          NoticeController(
            part("state", ""),
            tone: _error == null ? NoticeTone.plain : NoticeTone.warning,
            lines: [NoticeLine(_error ?? "Opening…")],
          ),
      ]),
    ];
  }
}
