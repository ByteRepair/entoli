import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:flutter/foundation.dart";
import "package:http/http.dart" as http;

import "../../domain/llm_provider.dart";
import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../domain/local_model_store.dart";

/// What is bundled to run a model with: llama.cpp's server, and the directory
/// its libraries and the NPU's own are in.
///
/// It is the native library directory, and that is not tidiness — it is the
/// only place an app targeting a modern Android may execute a file from, which
/// is the same rule that puts git and proot there. See "Bundled tools" in
/// CLAUDE.md. Here the directory is load-bearing twice over:
/// the CPU-side backends are resolved out of it by the dynamic linker, and the
/// Hexagon backend's DSP-side skeletons are resolved out of it by fastRPC.
class LlamaBinaries {
  const LlamaBinaries({required this.server, required this.libDir});

  final String server;
  final String libDir;

  /// What every invocation of [server] needs, whether it is serving a model or
  /// only being asked what devices it found. Here rather than at each call
  /// site: a build that grows a third variable would otherwise get it on the
  /// serving path and not on the probe, and the device list would quietly go
  /// empty.
  Map<String, String> get environment => {
        // The server is exec'd by path rather than loaded by the app, so the
        // linker has nothing to go on: libllama and every `libggml-*.so` beside
        // it are found through this and nothing else.
        "LD_LIBRARY_PATH": libDir,
        // Where fastRPC looks for the DSP-side half of the Hexagon backend.
        // Set whether or not this build carried one, since the answer is the
        // same directory either way.
        "ADSP_LIBRARY_PATH": libDir,
      };
}

/// How the server is invoked, and the environment that finds everything it
/// loads. A pure function over paths for the reason `prootSandbox` is one: what
/// the server is asked to do is the whole of what this feature does, and it is
/// the part of it that can be pinned by a test on a machine with no Android on
/// it.
({List<String> command, Map<String, String> environment}) llamaLaunch({
  required LlamaBinaries binaries,
  required LocalModel model,
  required String modelFile,
  required int port,
  required String apiKey,
  String? device,
  int? contextLength,
}) =>
    (
      command: [
        binaries.server,
        "-m", modelFile,
        // Loopback only. Anything else would put an unauthenticated model
        // server on the phone's network, which is a thing to be asked for
        // rather than a default.
        "--host", "127.0.0.1",
        "--port", "$port",
        // Every app on the device can reach the loopback address, so the key is
        // not ceremony: without one, any of them could spend this model's
        // battery. It is generated per launch and never written down.
        "--api-key", apiKey,
        // What the picker offers and what a chat's `meta.json` pins, rather
        // than the file name the weights happen to have arrived under.
        "-a", model.id,
        "-c", "${contextLength ?? defaultContextLength}",
        // The chat template as the publisher wrote it, which is what turns a
        // small model's tool call into an OpenAI one. Without it the agent's
        // tools reach a model that has never been told they exist.
        "--jinja",
        // Nobody is going to open this in a browser, and the assets are served
        // from the binary either way.
        "--no-webui",
        if (device != null) ...[
          "-dev", device,
          // Everything the device will take. A phone has no separate pool of
          // memory to run out of — the NPU and the GPU are addressing the same
          // RAM the model was already in — so holding layers back buys nothing.
          "-ngl", "999",
        ],
      ],
      environment: binaries.environment,
    );

/// What a model is run with when nothing says otherwise. Far below what any of
/// the catalog was trained for, and deliberately: the weights are mapped and
/// paged, while the KV cache is resident, so on a phone it is the context that
/// decides whether the app is killed.
const defaultContextLength = 4096;

/// llama.cpp's server, running beside the app and answering on the loopback
/// address.
class LlamaServer extends LocalLlm {
  LlamaServer(this._binaries, this._store);

  /// Never null: `platformLocalLlm` answers with [UnavailableLocalLlm] where
  /// this build shipped no server, so a [LlamaServer] that exists has one.
  final LlamaBinaries _binaries;

  /// Where the weights are. Asked synchronously at the moment of starting, so
  /// that a model deleted behind the app's back is a refusal here rather than a
  /// server that exits three seconds later saying it could not open a file.
  final LocalModelStore _store;

  @override
  final ValueNotifier<LocalLlmState> state = ValueNotifier(const LocalLlmState());

  Process? _process;

  /// Where the running server is and what it will answer to. One field rather
  /// than two, since they are made together and mean nothing apart — and null
  /// is the whole of "there is nothing to talk to".
  ({int port, String key})? _endpoint;

  /// Completed when the server answers, or completed with an error when it
  /// stops trying. Replaced per start, so a client that waited on a previous
  /// one is not left holding a future that will never move.
  Completer<void>? _ready;

  /// The tail of what the server said. Kept because the one failure that
  /// matters — a model that does not fit — is reported there and nowhere else.
  final _log = <String>[];

  static const _logLines = 40;

  @override
  bool get available => true;

  @override
  Future<void> whenReady() {
    final ready = _ready;
    if (ready == null) {
      return Future.error(StateError("No on-device model is loaded."));
    }
    return ready.future;
  }

  @override
  LlmProviderConfig? get provider {
    final at = _endpoint;
    if (at == null) return null;
    return LlmProviderConfig(
      id: localProviderId,
      label: "On-device",
      api: LlmApi.openai,
      baseUrl: "http://127.0.0.1:${at.port}/v1",
      apiKey: at.key,
      // Named rather than asked for. The endpoint would answer, but only once
      // it has finished loading, and the picker asks while it is still going.
      models: [state.value.modelId!],
    );
  }

  @override
  Future<List<LocalDevice>> devices() async {
    try {
      final result = await Process.run(
        _binaries.server,
        const ["--list-devices"],
        environment: _binaries.environment,
      );
      return parseDevices("${result.stdout}");
    } on ProcessException {
      return const [];
    }
  }

  @override
  Future<void> start(LocalModel model, {String? device, int? contextLength}) async {
    await stop();
    // The pick is published before anything can go wrong with it, so that every
    // failure below reads as this model failing rather than as nothing picked —
    // which is what the settings page draws and what a waiting turn is told.
    _log.clear();
    _ready = Completer<void>();
    state.value = LocalLlmState(
      phase: LocalLlmPhase.starting,
      modelId: model.id,
      device: device,
      contextLength: contextLength,
    );

    final file = _store.fileOfSync(model);
    if (file == null) return _fail("${model.name} is not downloaded.");

    // Asked of the OS rather than picked: a fixed port is one another app can
    // already be on, and the failure that gives is the server exiting a second
    // after it started for a reason nothing here would think to report.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final apiKey = _newKey();

    final launch = llamaLaunch(
      binaries: _binaries,
      model: model,
      modelFile: file,
      port: port,
      apiKey: apiKey,
      device: device,
      contextLength: contextLength,
    );
    _endpoint = (port: port, key: apiKey);

    try {
      final process = await Process.start(
        launch.command.first,
        launch.command.sublist(1),
        environment: launch.environment,
      );
      _process = process;
      // Both pipes, and interleaved: the server writes its progress to one and
      // its complaints to the other, and which is which has changed between
      // releases.
      for (final stream in [process.stdout, process.stderr]) {
        stream.transform(utf8.decoder).transform(const LineSplitter()).listen(_say);
      }
      // Named, rather than read off the field when it fires: by then the field
      // may hold the *next* server, and reporting this one's exit against it
      // would fail a model that is loading perfectly well.
      unawaited(process.exitCode.then((code) => _exited(process, code)));
      // Not awaited: this returns when the server is up, and the model behind
      // it is another minute. `state` and [whenReady] are what carry that.
      unawaited(_waitForHealth(_ready!, (port: port, key: apiKey)));
    } on ProcessException catch (e) {
      _fail(e.message);
    }
  }

  /// Never null, and that matters: this is what the settings page and a chat's
  /// stop button reach, and a load that has not finished must still be
  /// stoppable — the process is holding a gigabyte of the phone's memory while
  /// it maps.
  @override
  Future<void> stop() async {
    final process = _process;
    _process = null;
    _endpoint = null;
    // Before the kill, so the exit handler does not report a failure for a
    // server that was asked to go.
    _abandon(StateError("The on-device model was stopped."));
    _ready = null;
    state.value = const LocalLlmState();
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
    // Not awaited past a moment: a server mapping a large model can be slow to
    // notice, and nothing above here is waiting on the memory coming back.
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
  }

  /// Polled rather than watched for a line, since what the server prints when
  /// it is up is not part of any contract and its `/health` is.
  ///
  /// It loops on its own completer rather than on the process and the port,
  /// because everything that ends this wait already moves that one thing:
  /// [stop] abandons it, an exit reaches it through [_fail], and a start that
  /// supersedes this one stops first. One term instead of three that have to
  /// agree.
  Future<void> _waitForHealth(Completer<void> mine, ({int port, String key}) at) async {
    final client = http.Client();
    try {
      while (!mine.isCompleted) {
        try {
          final response = await client.get(
            Uri.parse("http://127.0.0.1:${at.port}/health"),
            headers: {"Authorization": "Bearer ${at.key}"},
          ).timeout(const Duration(seconds: 5));
          if (response.statusCode == 200) {
            state.value = _phase(LocalLlmPhase.ready);
            mine.complete();
            return;
          }
        } catch (_) {
          // Not up yet, which for the first few seconds is every answer there
          // is: the socket is not listening until the model has been read.
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      client.close();
    }
  }

  void _say(String line) {
    _log.add(line);
    if (_log.length > _logLines) _log.removeAt(0);
    if (kDebugMode) debugPrint("llama-server: $line");
  }

  void _exited(Process process, int code) {
    // Asked to stop, or replaced by a later start: [stop] has said so already.
    if (!identical(_process, process)) return;
    _process = null;
    _fail(_log.isEmpty ? "The model server exited ($code)." : _log.join("\n"));
  }

  /// The same pick, at another phase — so that what was asked for survives the
  /// server failing to deliver it, which is what the settings page redraws and
  /// what [applyLocalModel] compares against.
  LocalLlmState _phase(LocalLlmPhase phase, {String? failure}) => LocalLlmState(
        phase: phase,
        modelId: state.value.modelId,
        device: state.value.device,
        contextLength: state.value.contextLength,
        failure: failure,
      );

  /// Kept rather than cleared, so a turn sent at a model that will not load is
  /// told why instead of being told nothing is loaded.
  void _fail(String why) {
    state.value = _phase(LocalLlmPhase.failed, failure: why);
    _abandon(LocalLlmFailure(why));
  }

  /// Tell whoever is waiting that this attempt is over. [Future.ignore] is the
  /// half that is easy to forget: an error completed into a future nobody is
  /// waiting on is otherwise reported as unhandled, and usually nobody is.
  void _abandon(Object why) {
    final ready = _ready;
    if (ready == null || ready.isCompleted) return;
    ready.completeError(why);
    ready.future.ignore();
  }

  static String _newKey() {
    final random = Random.secure();
    return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, "0")]
        .join();
  }
}

/// Why the model is not answering, worded by the server. Its own type so the
/// agent's error arm can say "the on-device model" rather than reporting a
/// connection to localhost that was refused.
class LocalLlmFailure implements Exception {
  const LocalLlmFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What `--list-devices` printed. Accelerators only — ggml leaves the CPU out
/// of that list, since it is what runs when nothing is offloaded rather than
/// something to offload to.
///
/// Liberal on purpose: a line it cannot read is skipped rather than failing the
/// list, because what is at stake is one entry in a dropdown and the format is
/// a `printf` in somebody else's repository.
List<LocalDevice> parseDevices(String output) {
  final line = RegExp(r"^\s+(\S+):\s+(.*?)(?:\s+\((\d+) MiB[^)]*\))?\s*$");
  final devices = <LocalDevice>[];
  for (final text in const LineSplitter().convert(output)) {
    if (text.trimLeft().startsWith("(none)")) continue;
    final match = line.firstMatch(text);
    if (match == null) continue;
    final name = match.group(1)!;
    final total = int.tryParse(match.group(3) ?? "");
    devices.add(LocalDevice(
      name: name,
      description: match.group(2)!.trim(),
      compute: LocalDevice.computeOf(name),
      totalBytes: total == null ? null : total * 1024 * 1024,
    ));
  }
  return devices;
}
