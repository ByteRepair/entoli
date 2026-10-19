import "dart:async";
import "dart:convert";
import "dart:js_interop";
import "dart:js_interop_unsafe";
import "dart:typed_data";

import "package:fs_shim/fs.dart";
import "package:http/http.dart" as http;
import "package:web/web.dart" as web;

import "../../../data/web/guest_files.dart";
import "../../../data/web/guest_mux.dart";
import "../../log.dart";

/// The Linux this site serves beside the app, under `linux/` (built by
/// `tool/web/linux/build.sh`), and the one guest a page runs of it: booted in
/// a worker by the first command that needs it, then kept for the page's
/// life. See "The browser's Linux" in `lib/data/web/AGENTS.md`.
class BrowserLinux {
  BrowserLinux(this.fs, this.dataDir);

  final FileSystem fs;

  /// Where the guest mounts the app's files: the data directory's own path,
  /// so a path means the same on both sides.
  final String dataDir;

  ({String base, String alpine, String arch, int diskBytes, int chunk})? _image;

  Future<GuestMux>? _guest;

  /// The guest's console, the last of it, for the log line a boot that
  /// fails is worth.
  final List<String> _console = [];

  static const _memory = 512 * 1024 * 1024;
  static const _bootLimit = Duration(minutes: 4);

  /// Whether the site serves the image: a deployment built without
  /// `build.sh`, or a dev server without it run, has no `linux/image/`.
  Future<void> probe() async {
    try {
      // Past the browser's cache: the manifest is what names this deploy's
      // image, and an old one names files the deploy took away.
      final response = await http.get(Uri.base.resolve(
          "linux/image/manifest.json?${DateTime.now().millisecondsSinceEpoch}"));
      if (response.statusCode != 200) return;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final disk = json["disk"] as Map<String, dynamic>;
      _image = (
        base: json["base"] as String,
        alpine: json["alpine"] as String,
        arch: json["arch"] as String,
        diskBytes: disk["bytes"] as int,
        chunk: disk["chunk"] as int,
      );
    } catch (e) {
      logFailure("guest", "the Linux image's manifest did not load", e);
    }
  }

  bool get available => _image != null;

  /// What the model is told it is operating on, network and pace included:
  /// a model that does not know is one that waits on an `apk add`.
  String describe() {
    final image = _image;
    if (image == null) return "a browser, with no shell to run commands in";
    return "Alpine Linux ${image.alpine} (${image.arch}), emulated in this "
        "browser page. It has no network, so nothing can be downloaded or "
        "installed, and commands run many times slower than on a real machine";
  }

  /// The guest, booting it the first time. A boot that fails is forgotten,
  /// so the next command tries again rather than inheriting the failure.
  Future<GuestMux> guest() => _guest ??= _boot().catchError((Object e) {
        _guest = null;
        logFailure("guest", "the Linux did not boot: $e",
            _console.isEmpty ? null : _console.join(" | "));
        throw e;
      });

  Future<GuestMux> _boot() async {
    final image = _image;
    if (image == null) throw StateError("This site serves no Linux image.");
    final modes = GuestModes(fs, fs.path.join(dataDir, "guest-modes.json"));
    await modes.load();
    final files = GuestFileServer(fs, root: dataDir, modes: modes);
    final worker = web.Worker(Uri.base.resolve("linux/worker.js").toString().toJS);
    final mux = GuestMux((line) => worker.postMessage({
          "type": "send",
          "line": line,
        }.jsify()));
    final failed = Completer<void>();

    void onMessage(web.MessageEvent event) {
      final data = event.data as JSObject;
      final type = (data.getProperty<JSString>("type".toJS)).toDart;
      switch (type) {
        case "line":
          mux.receive(data.getProperty<JSString>("line".toJS).toDart);
        case "log":
          _console.add(data.getProperty<JSString>("line".toJS).toDart);
          if (_console.length > 40) _console.removeAt(0);
        case "9p":
          final request = data.getProperty<JSUint8Array>("message".toJS).toDart;
          files.handle(request).then((Uint8List reply) {
            final message = JSObject()
              ..setProperty("type".toJS, "9p".toJS)
              ..setProperty("message".toJS, reply.toJS);
            worker.postMessage(message, [reply.buffer.toJS].toJS);
          });
        case "error":
          final why = data.getProperty<JSString>("message".toJS).toDart;
          if (!mux.isReady && !failed.isCompleted) {
            failed.completeError(StateError(why));
          } else {
            logFailure("guest", why);
          }
      }
    }

    worker.onmessage = onMessage.toJS;
    worker.onerror = ((web.Event event) {
      final why = event.isA<web.ErrorEvent>()
          ? (event as web.ErrorEvent).message
          : "the worker failed";
      mux.close("The Linux in this page stopped: $why");
      if (!failed.isCompleted) failed.completeError(StateError(why));
    }).toJS;

    worker.postMessage({
      "type": "boot",
      "image": "image/${image.base}",
      "memory": _memory,
      "cmdline": "console=ttyS0 root=/dev/sda rootfstype=ext4 rw "
          "init=/sbin/entoli-init quiet tsc=reliable mitigations=off "
          "entoli.data=$dataDir",
      "disk": {"bytes": image.diskBytes, "chunk": image.chunk},
    }.jsify());

    // The mux says so as it starts; asking as well covers a page that was
    // not yet listening when it did.
    final ping = Timer.periodic(const Duration(seconds: 2), (_) => mux.ping());
    try {
      await Future.any([mux.ready, failed.future]).timeout(_bootLimit);
    } on TimeoutException {
      worker.terminate();
      throw StateError("it did not come up within ${_bootLimit.inMinutes} minutes");
    } catch (_) {
      worker.terminate();
      rethrow;
    } finally {
      ping.cancel();
    }
    return mux;
  }
}
