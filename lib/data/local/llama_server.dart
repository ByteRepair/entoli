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
import "../../core/log.dart";

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
  required int contextLength,
  required String device,
  int? threads,
  String? slotSavePath,
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
        // Always passed, and that is deliberate: llama.cpp's own `--fit` would
        // otherwise size this against the phone's whole RAM, since the CPU
        // backend reports every physical page as free. See "How much context"
        // in CLAUDE.md.
        "-c", "$contextLength",
        // The chat template as the publisher wrote it, which is what turns a
        // small model's tool call into an OpenAI one. Without it the agent's
        // tools reach a model that has never been told they exist.
        "--jinja",
        // Nobody is going to open this in a browser, and the assets are served
        // from the binary either way.
        "--no-webui",
        // Null is llama.cpp's own answer, which is every physical core.
        if (threads != null) ...["-t", "$threads"],
        // Where the slot dumps go, and — with it — quantised KV so a saved
        // conversation is half the bytes on disk. Both ride on the cache being
        // on: q8_0 KV is near-lossless but still a change to generation, so a
        // user who turned the cache off gets f16 and the behaviour they had.
        // The quant is part of the cache's namespace, so f16 and q8_0 dumps are
        // never mixed. See "Persisting the KV cache to disk" in CLAUDE.md.
        if (slotSavePath != null) ...[
          "--slot-save-path", slotSavePath,
          "-ctk", "q8_0",
          "-ctv", "q8_0",
        ],
        // Always named, [noDevice] included. See "The CPU is a device to name"
        // in CLAUDE.md.
        "-dev", device,
        if (device != noDevice) ...[
          // Everything the device will take. A phone has no separate pool of
          // memory to run out of — the NPU and the GPU are addressing the same
          // RAM the model was already in — so holding layers back buys nothing.
          "-ngl", "999",
        ],
      ],
      environment: binaries.environment,
    );

/// llama.cpp's own name for offloading nothing, which is the CPU. It has to be
/// passed rather than left out: no `-dev` at all is *auto* down there, and auto
/// is every GPU the phone has.
const noDevice = "none";

/// Which device a turn offloads to, given what the user chose and what the
/// phone turned out to have.
///
/// Three cases, and the first is the default. A null choice is *auto*, and auto
/// is the best accelerator the server found — an NPU over a GPU, and either over
/// running on the CPU. [LocalDevice.cpu] is how the picker says "the CPU even
/// so". Any other value is a device named outright, passed straight through — a
/// device that has since gone is llama.cpp's to complain about, not ours to
/// second-guess.
String resolveLocalDevice(String? chosen, List<LocalDevice> found) {
  if (chosen == LocalDevice.cpu) return noDevice;
  if (chosen != null) return chosen;
  return bestAccelerator(found)?.name ?? noDevice;
}

/// The accelerator to prefer when nothing was picked: an NPU before a GPU,
/// since on the one phone that reports both the NPU is the faster, and the
/// first of a kind otherwise. Null where the server found none — which is the
/// CPU, and is why not picking is never worse than picking.
LocalDevice? bestAccelerator(List<LocalDevice> found) {
  for (final kind in [LocalCompute.npu, LocalCompute.gpu]) {
    for (final device in found) {
      if (device.compute == kind) return device;
    }
  }
  return null;
}

/// The answer for this machine, read once. A lazy top-level `final` because the
/// cores do not change while the process lives, and every caller is on a path —
/// the first frame, and a settings page restarting the server — that has no
/// reason to read eight files again for a number that cannot have moved.
final int? _bigCores = bigCoreCount(cpuCeilings());

/// How many cores are worth running on, given what the kernel says each one's
/// ceiling is.
///
/// llama.cpp's own answer is every physical core, and on a phone that is wrong
/// in a way it is not on a desktop: the cores are not alike, and ggml's
/// threadpool moves at its slowest thread's pace, so a little core holds up
/// every big one it was scheduled beside. The little cluster is the one at the
/// lowest ceiling; everything above it is what to run on.
///
/// A machine whose cores are all one tier has no little cluster and gets all of
/// them, and so does one the kernel would not answer for — `threads` is null
/// there and llama.cpp decides, which is what happened before this existed.
int? bigCoreCount(List<int> ceilings) {
  if (ceilings.isEmpty) return null;
  final slowest = ceilings.reduce(min);
  final big = ceilings.where((each) => each > slowest).length;
  return big == 0 ? ceilings.length : big;
}

/// What the kernel says each core's ceiling is, out of Linux's `cpufreq` — in
/// whatever unit it uses, since only the ordering is read.
///
/// Linux rather than Android, and it needs no guard for it: this is only ever
/// reached from [LlamaServerPool], which `platformLocalLlm` builds on Android
/// alone, and a desktop Linux that got here through a hand-built binary would
/// be answering about its own cores, which is the right answer there too.
/// Anywhere else the files are missing and the list is empty.
///
/// Every core has to answer or none of them do. A core the kernel says nothing
/// about is one the others cannot be ranked against, and half a list read as a
/// whole one is a big cluster of the wrong size — which is worse than the
/// default this then falls back to.
List<int> cpuCeilings() {
  final ceilings = <int>[];
  for (var cpu = 0; cpu < Platform.numberOfProcessors; cpu++) {
    final file = File("/sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq");
    final value = file.existsSync() ? int.tryParse(file.readAsStringSync().trim()) : null;
    if (value == null) return const [];
    ceilings.add(value);
  }
  return ceilings;
}

/// llama.cpp's servers, running beside the app on the loopback address — one
/// process per model, up to what the settings allow.
class LlamaServerPool extends LocalLlm {
  LlamaServerPool(this._binaries, this._store, {this._slotSaveDir});

  /// Never null: `platformLocalLlm` answers with [UnavailableLocalLlm] where
  /// this build shipped no server, so a pool that exists has one.
  final LlamaBinaries _binaries;

  /// Where the server writes and reads its slot dumps, or null where this build
  /// has nowhere to keep them. One directory for every model — the dump's
  /// filename carries the namespace, so the server needs no per-model path. See
  /// [LocalKvCache].
  final String? _slotSaveDir;

  /// Where the weights are. Asked synchronously at the moment of starting, so
  /// that a model deleted behind the app's back is a refusal here rather than a
  /// server that exits three seconds later saying it could not open a file.
  final LocalModelStore _store;

  /// Least recently served first, which is the order [serve] evicts in.
  final _servers = <_Server>[];

  /// The device probe, run once. What the phone has cannot change while the
  /// process lives, and [serve] reads it on every auto turn — a fresh
  /// `--list-devices`, which spawns the server binary, is a cost to pay once.
  Future<List<LocalDevice>>? _deviceProbe;

  @override
  final ValueNotifier<List<LocalLlmState>> running = ValueNotifier(const []);

  @override
  bool get available => true;

  @override
  int? get maxThreads => _bigCores ?? Platform.numberOfProcessors;

  @override
  Future<List<LocalDevice>> devices() => _deviceProbe ??= _probeDevices();

  Future<List<LocalDevice>> _probeDevices() async {
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
  LlmProviderConfig? get provider {
    final models = [
      for (final model in localModelCatalog)
        if (_store.fileOfSync(model) != null) model.id,
    ];
    if (models.isEmpty) return null;
    return LlmProviderConfig(
      id: localProviderId,
      label: "On-device",
      api: LlmApi.openai,
      // Empty, and it has to be: there is no one server behind this entry, and
      // each model is its own process on a port of its own. The endpoint
      // carries the client that routes between them, so nothing reads this —
      // and an empty string keeps the registry's cache signature still while
      // servers come and go under it.
      baseUrl: "",
      models: models,
    );
  }

  @override
  Future<LocalEndpoint> serve(
    String modelId, {
    String? device,
    int? contextLength,
    int maxRunning = 1,
    int? threads,
    bool kvCache = false,
  }) async {
    final model = localModelById(modelId);
    if (model == null) throw LocalLlmFailure("$modelId is not a model this build knows.");
    final wanted = contextLength ?? model.defaultContext;
    // Only where there is somewhere to write them: a build with no cache dir
    // serves f16 whatever the setting says.
    final slotSavePath = kvCache ? _slotSaveDir : null;
    final wantThreads = threads ?? _bigCores;
    // Auto by default: a turn asks for a model, not a processor, and the best
    // accelerator the phone has beats the CPU by enough that picking it is not
    // a thing to make the user do. Only auto reads the device list, and probing
    // it spawns the server — so a named device, or the CPU chosen outright,
    // skips it. Resolved before the list below is touched, so the running-server
    // check compares the device actually used and not the word "auto", and two
    // auto turns arriving together still edit the list one after the other, each
    // resuming from this same await without yielding into it again.
    final resolved =
        resolveLocalDevice(device, device == null ? await devices() : const []);

    final already = _serverFor(modelId);
    if (already != null &&
        already.serves(
          device: resolved,
          contextLength: wanted,
          threads: wantThreads,
          slotSavePath: slotSavePath,
        )) {
      _touch(already);
      await already.ready;
      return already.endpoint;
    }

    final file = _store.fileOfSync(model);
    if (file == null) throw LocalLlmFailure("${model.name} is not downloaded.");

    // Every list edit below happens before the first await, so two turns asking
    // at once cannot both decide to start the same model — the second finds the
    // first already in the list and waits on it.
    final stopping = <_Server>[];
    if (already != null) {
      _servers.remove(already);
      stopping.add(already);
    }
    final cap = maxRunning.clamp(1, maxLocalModelsAllowed);
    while (_servers.length >= cap) {
      stopping.add(_servers.removeAt(0));
    }
    final server = _Server(
      model: model,
      device: resolved,
      contextLength: wanted,
      threads: wantThreads,
      slotSavePath: slotSavePath,
    );
    _servers.add(server);
    _publish();

    // The old ones go before the new one arrives. Overlapping them would put
    // two sets of weights in memory at once, which is the thing the cap exists
    // to prevent.
    for (final old in stopping) {
      await old.stop();
    }
    await server.spawn(_binaries, file, onChange: _publish);
    await server.ready;
    return server.endpoint;
  }

  @override
  Future<void> stopAll() async {
    final all = [..._servers];
    _servers.clear();
    _publish();
    for (final server in all) {
      await server.stop();
    }
  }

  _Server? _serverFor(String modelId) {
    for (final server in _servers) {
      if (server.model.id == modelId) return server;
    }
    return null;
  }

  /// Most recently served last, since that is the end [serve] evicts from.
  void _touch(_Server server) {
    if (_servers.remove(server)) _servers.add(server);
    _publish();
  }

  void _publish() => running.value = [for (final server in _servers) server.state];
}

/// One model, one process.
class _Server {
  _Server({
    required this.model,
    required this.device,
    required this.contextLength,
    required this.threads,
    required this.slotSavePath,
  });

  final LocalModel model;
  final String device;
  final int contextLength;
  final int? threads;
  final String? slotSavePath;

  Process? _process;

  /// Where this one is and what it will answer to. One field rather than two,
  /// since they are made together and mean nothing apart — and null is the
  /// whole of "it has not been spawned yet".
  ({int port, String key})? _at;

  final _ready = Completer<void>();
  var _phase = LocalLlmPhase.starting;
  String? _failure;

  /// The tail of what the server said. Kept because the one failure that
  /// matters — a model that does not fit — is reported there and nowhere else.
  final _log = <String>[];

  static const _logLines = 40;

  Future<void> get ready => _ready.future;

  LocalLlmState get state => LocalLlmState(
        modelId: model.id,
        phase: _phase,
        // In the picker's word rather than llama.cpp's: [noDevice] is a flag
        // value, and what reads this is the settings page.
        device: device == noDevice ? LocalDevice.cpu : device,
        contextLength: contextLength,
        failure: _failure,
      );

  /// Only read after [ready] has completed, which is the only point at which
  /// there is something on the other end of it.
  LocalEndpoint get endpoint => LocalEndpoint(
        baseUrl: "http://127.0.0.1:${_at!.port}/v1",
        apiKey: _at!.key,
        contextLength: contextLength,
      );

  /// Whether this is still the server that would be started for these settings.
  /// A failed one never is: being asked again is the user asking for another
  /// go, and there is nothing else they could press to get one.
  bool serves({
    required String device,
    required int contextLength,
    required int? threads,
    required String? slotSavePath,
  }) =>
      _phase != LocalLlmPhase.failed &&
      this.device == device &&
      this.contextLength == contextLength &&
      this.threads == threads &&
      this.slotSavePath == slotSavePath;

  Future<void> spawn(LlamaBinaries binaries, String modelFile,
      {required void Function() onChange}) async {
    // Asked of the OS rather than picked: a fixed port is one another app can
    // already be on, and the failure that gives is the server exiting a second
    // after it started for a reason nothing here would think to report.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final at = (port: socket.port, key: _newKey());
    await socket.close();
    _at = at;

    final launch = llamaLaunch(
      binaries: binaries,
      model: model,
      modelFile: modelFile,
      port: at.port,
      apiKey: at.key,
      contextLength: contextLength,
      device: device,
      threads: threads,
      slotSavePath: slotSavePath,
    );

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
      // may hold nothing, and reporting this one's exit against it would fail a
      // model that is loading perfectly well.
      unawaited(process.exitCode.then((code) => _exited(process, code, onChange)));
      unawaited(_waitForHealth(at, onChange));
    } on ProcessException catch (e) {
      _fail(e.message);
      onChange();
    }
  }

  /// Never awaited past a moment: a server mapping a large model can be slow to
  /// notice, and nothing waiting on this is waiting on the memory coming back.
  Future<void> stop() async {
    final process = _process;
    _process = null;
    // Before the kill, so the exit handler does not report a failure for a
    // server that was asked to go.
    _abandon(const LocalLlmFailure("The on-device model was stopped."));
    if (process == null) return;
    process.kill(ProcessSignal.sigterm);
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
  Future<void> _waitForHealth(({int port, String key}) at, void Function() onChange) async {
    final client = http.Client();
    try {
      while (!_ready.isCompleted) {
        try {
          final response = await client.get(
            Uri.parse("http://127.0.0.1:${at.port}/health"),
            headers: {"Authorization": "Bearer ${at.key}"},
          ).timeout(const Duration(seconds: 5));
          if (response.statusCode == 200) {
            _phase = LocalLlmPhase.ready;
            _ready.complete();
            onChange();
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
    logDetail("llama", () => "${model.id}: $line");
  }

  void _exited(Process process, int code, void Function() onChange) {
    // Asked to stop, or already gone: [stop] has said so.
    if (!identical(_process, process)) return;
    _process = null;
    _fail(_log.isEmpty ? "The model server exited ($code)." : _log.join("\n"));
    onChange();
  }

  /// Kept rather than cleared, so a turn sent at a model that will not load is
  /// told why instead of being told nothing is loaded.
  void _fail(String why) {
    _phase = LocalLlmPhase.failed;
    _failure = why;
    _abandon(LocalLlmFailure(why));
  }

  /// Tell whoever is waiting that this attempt is over. [Future.ignore] is the
  /// half that is easy to forget: an error completed into a future nobody is
  /// waiting on is otherwise reported as unhandled, and usually nobody is.
  void _abandon(Object why) {
    if (_ready.isCompleted) return;
    _ready.completeError(why);
    _ready.future.ignore();
  }

  static String _newKey() {
    final random = Random.secure();
    return [for (var i = 0; i < 16; i++) random.nextInt(256).toRadixString(16).padLeft(2, "0")]
        .join();
  }
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
