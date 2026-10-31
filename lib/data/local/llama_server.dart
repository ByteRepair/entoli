import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math";

import "package:http/http.dart" as http;
import "package:path/path.dart" as p;

import "../../domain/local_llm.dart";
import "../../domain/local_model.dart";
import "../../core/log.dart";
import "../../core/random_token.dart";
import "../builtin/llm/llm_client.dart";
import "../builtin/llm/openai_client.dart";
import "local_instance.dart";

/// What is bundled to run a model with: llama.cpp's server, and the directory
/// its libraries and the NPU's own are in.
///
/// It is the native library directory, and that is not tidiness — it is the
/// only place an app targeting a modern Android may execute a file from, which
/// is the same rule that puts git and proot there. See "Bundled tools" in
/// AGENTS.md. Here the directory is load-bearing twice over:
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
/// loads. A pure function over paths for the reason `prootDriver` is one: what
/// the server is asked to do is the whole of what this feature does, and it is
/// the part of it that can be pinned by a test on a machine with no Android on
/// it.
({List<String> command, Map<String, String> environment}) llamaLaunch({
  required LlamaBinaries binaries,
  required DownloadedModel model,
  required LocalLoad load,
  required int port,
  required String apiKey,
  String? slotSavePath,
  bool fitLayers = false,
}) => (
  command: [
    binaries.server,
    "-m", model.file,
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
    // in AGENTS.md.
    "-c", "${load.contextLength}",
    // One slot, since the disk cache is `/slots/0`'s, and no 8 GiB RAM
    // prompt cache beside it. See "That `/slots/0` is why the server has
    // one slot" in AGENTS.md.
    "-np", "1",
    "--cache-ram", "0",
    // The chat template as the publisher wrote it, which is what turns a
    // small model's tool call into an OpenAI one. Without it the agent's
    // tools reach a model that has never been told they exist.
    "--jinja",
    // Nobody is going to open this in a browser, and the assets are served
    // from the binary either way.
    "--no-webui",
    // Null is llama.cpp's own answer, which is every physical core.
    if (load.threads case final threads?) ...["-t", "$threads"],
    // Where the slot dumps go, and — with it — quantised KV so a saved
    // conversation is half the bytes on disk. Both ride on the cache being
    // on: q8_0 KV is near-lossless but still a change to generation, so a
    // user who turned the cache off gets f16 and the behaviour they had.
    // The quant is part of the cache's namespace, so f16 and q8_0 dumps are
    // never mixed. See "Persisting the KV cache to disk" in AGENTS.md.
    if (slotSavePath != null) ...[
      "--slot-save-path",
      slotSavePath,
      "-ctk",
      "q8_0",
      "-ctv",
      "q8_0",
    ],
    // Always named, [noDevice] included. See "The CPU is a device to name"
    // in AGENTS.md.
    "-dev", load.device ?? noDevice,
    // Every layer on a phone, whose accelerators share the RAM the weights
    // are in; `--fit`'s split on a laptop. See "How many layers go to the
    // GPU" in AGENTS.md.
    if (load.device != noDevice && !fitLayers) ...["-ngl", "999"],
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
/// lowest ceiling; everything clearly above it is what to run on.
///
/// "Clearly" is a tenth: AMD's preferred-core ranking gives each core of one
/// tier a slightly different ceiling, and splitting on that would drop cores
/// that are as fast as the rest. Real tiers are further apart — a phone's
/// little cluster, a laptop's E-cores.
///
/// A machine whose cores are all one tier has no little cluster and gets all of
/// them, and so does one the kernel would not answer for — `threads` is null
/// there and llama.cpp decides, which is what happened before this existed.
int? bigCoreCount(List<int> ceilings) {
  if (ceilings.isEmpty) return null;
  final floor = ceilings.reduce(min) * 1.1;
  final big = ceilings.where((each) => each > floor).length;
  return big == 0 ? ceilings.length : big;
}

/// What the kernel says each core's ceiling is, out of Linux's `cpufreq` — in
/// whatever unit it uses, since only the ordering is read. One entry per
/// physical core: a hyperthread sibling is skipped, since two threads on one
/// core's math units are slower than one, and counting them put a laptop's
/// P-cores in twice.
///
/// Linux rather than Android, and it needs no guard for it: this is only ever
/// reached from [LlamaRuntime], which `createLocalEngine` builds on Android
/// and Linux, and a desktop Linux answering about its own cores is the right
/// answer there too. Anywhere else the files are missing and the list is empty.
///
/// Every core has to answer or none of them do. A core the kernel says nothing
/// about is one the others cannot be ranked against, and half a list read as a
/// whole one is a big cluster of the wrong size — which is worse than the
/// default this then falls back to.
List<int> cpuCeilings({String root = "/sys/devices/system/cpu", int? cpus}) {
  final ceilings = <int>[];
  for (var cpu = 0; cpu < (cpus ?? Platform.numberOfProcessors); cpu++) {
    final file = File("$root/cpu$cpu/cpufreq/cpuinfo_max_freq");
    final value = file.existsSync()
        ? int.tryParse(file.readAsStringSync().trim())
        : null;
    if (value == null) return const [];
    if (_firstSibling(root, cpu) == cpu) ceilings.add(value);
  }
  return ceilings;
}

/// The lowest-numbered CPU sharing [cpu]'s core, out of a list like `0-1` or
/// `0,8`. A kernel that does not say is a core of its own.
int _firstSibling(String root, int cpu) {
  final file = File("$root/cpu$cpu/topology/thread_siblings_list");
  if (!file.existsSync()) return cpu;
  final first = file.readAsStringSync().trim().split(_listSeparator).first;
  return int.tryParse(first) ?? cpu;
}

final _listSeparator = RegExp("[,-]");

/// llama.cpp's servers, running beside the app on the loopback address — one
/// process per model. Which ones are loaded is [Residency]'s; what is here is
/// how one is loaded, and what a device and a thread count mean to it.
class LlamaRuntime extends LocalRuntime {
  LlamaRuntime(this._binaries, {this._slotSaveDir, this._fitLayers = false});

  /// Whether llama.cpp sizes the GPU layers itself — a laptop, whose GPU may
  /// have less memory than the model — rather than taking all of them, as a
  /// phone's shared memory can. See [llamaLaunch].
  final bool _fitLayers;

  /// Never null: `createLocalEngine` answers with `NoLocalEngine` where this
  /// build shipped no server, so a runtime that exists has one.
  final LlamaBinaries _binaries;

  /// Where the server writes and reads its slot files: the prompt cache's
  /// directory, or null where this build keeps none. One directory for every
  /// model — the file's name carries the namespace.
  final String? _slotSaveDir;

  /// The device probe, run once. What the phone has cannot change while the
  /// process lives, and [resolve] reads it on every auto turn — a fresh
  /// `--list-devices`, which spawns the server binary, is a cost to pay once.
  Future<List<LocalDevice>>? _deviceProbe;

  static final _controls = LocalControl.values.toSet();

  @override
  Set<LocalControl> get controls => _controls;

  @override
  int? get maxThreads => _bigCores ?? Platform.numberOfProcessors;

  @override
  Future<List<LocalDevice>> devices() => _deviceProbe ??= _probeDevices();

  Future<List<LocalDevice>> _probeDevices() async {
    try {
      final result = await Process.run(_binaries.server, const [
        "--list-devices",
      ], environment: _binaries.environment);
      return parseDevices("${result.stdout}");
    } on ProcessException catch (e) {
      logFailure("llama", "device probe failed", e.message);
      return const [];
    }
  }

  /// Auto by default: a turn asks for a model, not a processor, and the best
  /// accelerator the phone has beats the CPU by enough that picking it is not a
  /// thing to make the user do. Only auto reads the device list, and probing it
  /// spawns the server — so a named device, or the CPU chosen outright, skips
  /// it. Resolved before [Residency] compares, so it compares the device
  /// actually used and not the word "auto".
  @override
  Future<LocalLoad> resolve(DownloadedModel model, LocalOptions options) async {
    final device = resolveLocalDevice(
      options.device,
      options.device == null ? await devices() : const [],
    );
    return LocalLoad(
      contextLength: options.contextLength ?? model.defaultContext,
      device: device,
      threads: options.threads ?? _bigCores,
      // Only where there is somewhere to write them: a build with no cache
      // directory serves f16 whatever the setting says.
      keepsPrompts: options.keepsPrompts && _slotSaveDir != null,
    );
  }

  @override
  LocalInstance create(
    DownloadedModel model,
    LocalLoad load, {
    required void Function() onChange,
  }) => LlamaInstance(
    model,
    load,
    binaries: _binaries,
    fitLayers: _fitLayers,
    slotSavePath: load.keepsPrompts ? _slotSaveDir : null,
    onChange: onChange,
  );
}

/// One model, one process: a llama.cpp server on a port of its own, reached
/// with the `/chat/completions` shape [OpenAiClient] speaks — tool calls
/// included, which is what the server is for.
class LlamaInstance extends LocalInstance {
  LlamaInstance(
    super.model,
    super.load, {
    required this._binaries,
    required this._fitLayers,
    required this.slotSavePath,
    required super.onChange,
  });

  final LlamaBinaries _binaries;
  final bool _fitLayers;

  /// Where the server writes slot files, or null where it keeps none.
  final String? slotSavePath;

  final _http = http.Client();

  /// One client for the server's life, made once it answers.
  OpenAiClient? _client;

  Process? _process;

  /// Where this one is and what it will answer to. One field rather than two,
  /// since they are made together and mean nothing apart — and null is the
  /// whole of "it has not been spawned yet".
  ({int port, String key})? _at;

  /// The tail of what the server said. Kept because the one failure that
  /// matters — a model that does not fit — is reported there and nowhere else.
  final _log = <String>[];

  static const _logLines = 40;

  /// In the picker's word rather than llama.cpp's: [noDevice] is a flag
  /// value, and what reads this is the settings page.
  @override
  String? get deviceLabel =>
      load.device == noDevice ? LocalDevice.cpu : load.device;

  /// The fixed KV quant llama.cpp runs with when caching is on, named so that
  /// turning the cache off (f16) and on again cannot cross-load a file.
  @override
  String get stateFormat => "q8";

  /// llama.cpp's own `prompt_progress` is asked for, which is what turns a
  /// minute of reading the prompt into something the chat can draw. A hosted
  /// provider would reject the field, which is why it rides on this client
  /// rather than on every request the app makes.
  @override
  Stream<LlmChunk> generate(
    List<LlmMessage> messages, {
    List<LlmTool> tools = const [],
    double? temperature,
    String? reasoningEffort,
  }) =>
      (_client ??= OpenAiClient(
        baseUrl: Uri.parse("http://127.0.0.1:${_at!.port}/v1"),
        apiKey: _at!.key,
        returnProgress: true,
      )).stream(
        messages,
        model: model.id,
        tools: tools,
        temperature: temperature,
        reasoningEffort: reasoningEffort,
      );

  /// The server's resident memory: one process per model, so all of it is
  /// this model's — the weights, the KV cache and whatever the server keeps
  /// beside them.
  @override
  Future<LocalUsage?> usage() async {
    final process = _process;
    if (process == null) return null;
    try {
      final status = await File("/proc/${process.pid}/status").readAsString();
      final bytes = residentBytes(status);
      return bytes == null ? null : LocalUsage(bytes: bytes);
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<bool> saveState(String path) => _slot("save", path);

  @override
  Future<bool> restoreState(String path) => _slot("restore", path);

  /// The server's slot save and restore. One slot (`-np 1`), so `/slots/0` is
  /// the state every turn ran in. The server takes a name in its
  /// `--slot-save-path`, which is the prompt cache's directory.
  Future<bool> _slot(String action, String path) async {
    final at = _at;
    if (at == null || slotSavePath == null) return false;
    try {
      final response = await _http
          .post(
            Uri.parse("http://127.0.0.1:${at.port}/slots/0?action=$action"),
            headers: {
              "content-type": "application/json",
              "authorization": "Bearer ${at.key}",
            },
            body: jsonEncode({"filename": p.basename(path)}),
          )
          .timeout(const Duration(seconds: 30));
      final ok = response.statusCode == 200;
      // A build without slot save/restore compiled in answers 501, and a
      // restore of a file the current weights cannot read fails too — both
      // are a miss to fall back from, not a turn to break.
      if (!ok) logFailure("kv-cache", "$action refused", response.statusCode);
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// `setpriv --pdeathsig` has the kernel stop the server when the app dies,
  /// which a crash or a SIGKILL otherwise leaves holding the model's memory.
  /// It fires when the spawning thread goes, and the spawn is on the root
  /// isolate's UI thread, which lives as long as the app. Linux only.
  static final List<String> _deathTie = () {
    if (!Platform.isLinux) return const <String>[];
    for (final dir in (Platform.environment["PATH"] ?? "").split(":")) {
      if (dir.isEmpty) continue;
      final setpriv = "$dir/setpriv";
      if (File(setpriv).existsSync()) return [setpriv, "--pdeathsig", "TERM"];
    }
    return const <String>[];
  }();

  @override
  void start() => unawaited(_spawn());

  Future<void> _spawn() async {
    // Asked of the OS rather than picked: a fixed port is one another app can
    // already be on, and the failure that gives is the server exiting a second
    // after it started for a reason nothing here would think to report.
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final at = (port: socket.port, key: randomToken(16));
    await socket.close();
    _at = at;

    final launch = llamaLaunch(
      binaries: _binaries,
      model: model,
      load: load,
      port: at.port,
      apiKey: at.key,
      slotSavePath: slotSavePath,
      fitLayers: _fitLayers,
    );

    try {
      final command = [..._deathTie, ...launch.command];
      final process = await Process.start(
        command.first,
        command.sublist(1),
        environment: launch.environment,
      );
      _process = process;
      // Both pipes, and interleaved: the server writes its progress to one and
      // its complaints to the other, and which is which has changed between
      // releases.
      for (final stream in [process.stdout, process.stderr]) {
        stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(_say);
      }
      // Named, rather than read off the field when it fires: by then the field
      // may hold nothing, and reporting this one's exit against it would fail a
      // model that is loading perfectly well.
      unawaited(process.exitCode.then((code) => _exited(process, code)));
      unawaited(_waitForHealth(at));
    } on ProcessException catch (e) {
      markFailed(e.message);
    }
  }

  /// The process is let go of before the kill, so the exit handler does not
  /// report a failure for a server that was asked to go.
  @override
  Future<void> unload() async {
    final process = _process;
    _process = null;
    _client?.close();
    _http.close();
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
  Future<void> _waitForHealth(({int port, String key}) at) async {
    final client = http.Client();
    try {
      while (state.phase == LocalLlmPhase.starting && _process != null) {
        try {
          final response = await client
              .get(
                Uri.parse("http://127.0.0.1:${at.port}/health"),
                headers: {"Authorization": "Bearer ${at.key}"},
              )
              .timeout(const Duration(seconds: 5));
          if (response.statusCode == 200) {
            markReady();
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

  void _exited(Process process, int code) {
    // Asked to stop, or already gone: [unload] has let it go.
    if (!identical(_process, process)) return;
    _process = null;
    markFailed(
      _log.isEmpty ? "The model server exited ($code)." : _log.join("\n"),
    );
  }
}

/// `VmRSS` out of a `/proc/<pid>/status`, in bytes. Null where it is not
/// there.
int? residentBytes(String status) {
  final match = RegExp(
    r"^VmRSS:\s+(\d+) kB",
    multiLine: true,
  ).firstMatch(status);
  return match == null ? null : int.parse(match.group(1)!) * 1024;
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
    devices.add(
      LocalDevice(
        name: name,
        description: match.group(2)!.trim(),
        compute: LocalDevice.computeOf(name),
        totalBytes: total == null ? null : total * 1024 * 1024,
      ),
    );
  }
  return devices;
}
