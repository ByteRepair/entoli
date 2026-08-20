import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/local/llama_server.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/domain/download.dart";
import "package:agent_chat/domain/local_model_store.dart";

/// What the server is asked to do is the whole of what running a model on the
/// device does, and it is the part of it that can be pinned on a machine with
/// no Android on it — the bargain `proot_test.dart` already makes.
void main() {
  const binaries = LlamaBinaries(
    server: "/data/app/pkg/lib/arm64/libllama-server.so",
    libDir: "/data/app/pkg/lib/arm64",
  );
  final model = localModelCatalog.first;

  ({List<String> command, Map<String, String> environment}) launch({
    String? device,
    int? contextLength,
  }) =>
      llamaLaunch(
        binaries: binaries,
        model: model,
        modelFile: "/cache/llm/${model.id}/model.gguf",
        port: 41234,
        apiKey: "abcdef",
        device: device,
        contextLength: contextLength,
      );

  /// The value of the argument after [flag], or null where it was not passed.
  String? valueOf(List<String> command, String flag) {
    for (var i = 0; i < command.length - 1; i++) {
      if (command[i] == flag) return command[i + 1];
    }
    return null;
  }

  test("it is bound to loopback and to a key nobody else was given", () {
    final it = launch();

    expect(valueOf(it.command, "--host"), "127.0.0.1");
    expect(valueOf(it.command, "--port"), "41234");
    // Every app on the device can reach the loopback address, so this is the
    // whole of what stops one of them spending the model's battery.
    expect(valueOf(it.command, "--api-key"), "abcdef");
  });

  test("the model is served under its catalog id, not its file name", () {
    // What the picker offers and what a chat's `meta.json` pins. The file is
    // `model.gguf` for every one of them, so without this they would all be
    // called the same thing.
    expect(valueOf(launch().command, "-a"), model.id);
    expect(valueOf(launch().command, "-m"), "/cache/llm/${model.id}/model.gguf");
  });

  test("the chat template is applied, since that is what tool calls are", () {
    expect(launch().command, contains("--jinja"));
  });

  test("nothing is offloaded unless a device was named", () {
    final cpu = launch();

    expect(cpu.command, isNot(contains("-dev")));
    // Without a device to put them on, asking for layers is a warning at
    // startup and nothing else.
    expect(cpu.command, isNot(contains("-ngl")));
  });

  test("a named device gets every layer", () {
    final npu = launch(device: "HTP0");

    expect(valueOf(npu.command, "-dev"), "HTP0");
    // A phone has no separate pool of memory to run out of, so holding layers
    // back on the CPU buys nothing.
    expect(int.parse(valueOf(npu.command, "-ngl")!), greaterThan(100));
  });

  test("the context is the default until something says otherwise", () {
    expect(valueOf(launch().command, "-c"), "$defaultContextLength");
    expect(valueOf(launch(contextLength: 16384).command, "-c"), "16384");
  });

  test("both library paths name the native library directory", () {
    final it = launch();

    // The linker's, for libllama and the backends beside it.
    expect(it.environment["LD_LIBRARY_PATH"], binaries.libDir);
    // fastRPC's, for the DSP-side half of the Hexagon backend. Set whether or
    // not this build carried one: the answer is the same directory either way,
    // and a build that grows the NPU should not also have to grow a line here.
    expect(it.environment["ADSP_LIBRARY_PATH"], binaries.libDir);
  });

  group("what the server says it has", () {
    test("an NPU and a GPU are told apart by name", () {
      final devices = parseDevices("""
Available devices:
  HTP0: Hexagon NPU (3584 MiB, 3584 MiB free)
  Vulkan0: Adreno (TM) 750 (11000 MiB, 11000 MiB free)
""");

      expect(devices.map((d) => d.name), ["HTP0", "Vulkan0"]);
      expect(devices.map((d) => d.compute), [LocalCompute.npu, LocalCompute.gpu]);
      expect(devices.first.description, "Hexagon NPU");
      expect(devices.first.totalBytes, 3584 * 1024 * 1024);
    });

    test("a phone with no accelerator is an empty list, not a failure", () {
      // The CPU is never in this list — it is what runs when nothing is
      // offloaded — so `(none)` is the answer on most phones and has to read as
      // "the CPU" rather than as an error.
      expect(parseDevices("Available devices:\n  (none)\n"), isEmpty);
      expect(parseDevices(""), isEmpty);
    });

    test("a line it cannot read is skipped rather than failing the list", () {
      // The format is a `printf` in somebody else's repository, and what is at
      // stake is one entry in a dropdown.
      final devices = parseDevices("""
Available devices:
  HTP0: Hexagon NPU (3584 MiB, 3584 MiB free)
something else entirely
""");

      expect(devices.map((d) => d.name), ["HTP0"]);
    });

    test("a device that says nothing about its memory still lists", () {
      final devices = parseDevices("Available devices:\n  Vulkan0: Mali-G715\n");

      expect(devices.single.name, "Vulkan0");
      expect(devices.single.description, "Mali-G715");
      expect(devices.single.totalBytes, isNull);
    });
  });

  /// A server that cannot possibly come up, over weights that are claimed to be
  /// there: `/bin/false` exits the moment it is started, which is what a real
  /// one does when the model will not fit. Real code all the way down — the
  /// process really is spawned — so this is the one thing about the running
  /// server that a machine with no Android on it can check.
  group("a start that fails", () {
    LlamaServer failing() => LlamaServer(
          const LlamaBinaries(server: "/bin/false", libDir: "/nonexistent"),
          _AlwaysInstalled(),
        );

    Future<void> settle(LlamaServer server) async {
      for (var i = 0; i < 100 && server.state.value.phase != LocalLlmPhase.failed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    test("the endpoint stays in the list, so a turn is told why", () async {
      final server = failing();
      await server.start(localModelCatalog.first);
      await settle(server);

      // Dropping it would leave a chat pinned to this model reporting that no
      // provider is configured, which says nothing about what went wrong.
      expect(server.provider, isNotNull);
      expect(server.provider!.id, localProviderId);
      expect(server.provider!.models, [localModelCatalog.first.id]);
      // Loopback, and a key generated for this launch.
      expect(server.provider!.baseUrl, startsWith("http://127.0.0.1:"));
      expect(server.provider!.apiKey, isNotEmpty);
    });

    test("what is waiting on it is told the server's own last words", () async {
      final server = failing();
      await server.start(localModelCatalog.first);
      await settle(server);

      expect(server.state.value.failure, isNotEmpty);
      await expectLater(server.whenReady(), throwsA(isA<LocalLlmFailure>()));
    });

    test("a model that is not downloaded is refused before anything is spawned",
        () async {
      final server = LlamaServer(
        const LlamaBinaries(server: "/bin/false", libDir: "/nonexistent"),
        const UnavailableLocalModelStore(),
      );

      await server.start(localModelCatalog.first);

      expect(server.state.value.phase, LocalLlmPhase.failed);
      // Nothing was started, so there is nothing to offer — unlike above, where
      // the failure is worth carrying to whoever asks.
      expect(server.provider, isNull);
    });
  });
}

/// Says every model is on disk, at a path nothing will open.
class _AlwaysInstalled extends LocalModelStore {
  const _AlwaysInstalled();

  @override
  Future<Set<String>> installed() async => const {};

  @override
  String? fileOfSync(LocalModel model) => "/nonexistent/${model.id}.gguf";

  @override
  Stream<DownloadProgress> install(LocalModel model) => const Stream.empty();

  @override
  Future<void> delete(LocalModel model) async {}
}
