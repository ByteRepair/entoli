import "dart:io";

import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/builtin/llm/hosted_models.dart";
import "package:agent_chat/data/builtin/llm/local_pool_client.dart";
import "package:agent_chat/data/local/llama_server.dart";
import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/local_llm.dart";
import "package:agent_chat/domain/model_registry.dart";
import "package:agent_chat/domain/local_model.dart";
import "package:agent_chat/domain/download.dart";
import "package:agent_chat/domain/local_model_store.dart";

import "../../fakes.dart" show downloadedAs;

/// What the server is asked to do is the whole of what running a model on the
/// device does, and it is the part of it that can be pinned on a machine with
/// no Android on it — the bargain `proot_test.dart` already makes.
void main() {
  const binaries = LlamaBinaries(
    server: "/data/app/pkg/lib/arm64/libllama-server.so",
    libDir: "/data/app/pkg/lib/arm64",
  );
  final model = downloadedAs(localModelCatalog.first);
  OnDeviceProvider onDevice(LocalLlm pool) =>
      OnDeviceProvider(pool, () => poolOptions(AppSettings()), voices: () => const {});

  ({List<String> command, Map<String, String> environment}) launch({
    String device = noDevice,
    int? contextLength,
    int? threads,
    String? slotSavePath,
    bool fitLayers = false,
  }) =>
      llamaLaunch(
        binaries: binaries,
        model: model,
        modelFile: "/cache/llm/${model.id}/model.gguf",
        port: 41234,
        apiKey: "abcdef",
        device: device,
        contextLength: contextLength ?? model.defaultContext,
        threads: threads,
        slotSavePath: slotSavePath,
        fitLayers: fitLayers,
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

  test("one slot and no RAM prompt cache", () {
    final it = launch();

    // The disk cache saves and restores slot 0, so a turn must run there.
    expect(valueOf(it.command, "-np"), "1");
    // Its default is 8 GiB of host memory no budget here counts.
    expect(valueOf(it.command, "--cache-ram"), "0");
  });

  test("the chat template is applied, since that is what tool calls are", () {
    expect(launch().command, contains("--jinja"));
  });

  test("the CPU is asked for by name, since leaving it out means auto", () {
    final cpu = launch();

    // The literal, not the constant: what is under test is the word llama.cpp
    // takes, which a rename of the constant must not quietly change.
    expect(valueOf(cpu.command, "-dev"), "none");
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

  test("a laptop leaves the layers to --fit", () {
    // A discrete GPU smaller than the model fails to load with every layer on
    // it, and an explicit -ngl is what turns fitting off.
    final gpu = launch(device: "Vulkan0", fitLayers: true);

    expect(valueOf(gpu.command, "-dev"), "Vulkan0");
    expect(gpu.command, isNot(contains("-ngl")));
  });

  group("how many cores it runs on", () {
    test("the little cluster is left out of the count", () {
      // Four big and four little, which is the common phone. ggml's threadpool
      // moves at its slowest thread's pace, so the little four would hold up
      // the big four rather than adding to them.
      expect(
        bigCoreCount([1800000, 1800000, 1800000, 1800000, 2800000, 2800000, 2800000, 2800000]),
        4,
      );
      // One prime, three mid, four little: everything above the floor.
      expect(
        bigCoreCount([1900000, 1900000, 1900000, 1900000, 2600000, 2600000, 2600000, 3200000]),
        4,
      );
    });

    test("cores that are all one tier are all worth running on", () {
      expect(bigCoreCount([2000000, 2000000, 2000000, 2000000]), 4);
      // AMD's preferred-core ranking: one tier, ceilings a few percent apart.
      expect(bigCoreCount([5100000, 5050000, 4950000, 4900000]), 4);
    });

    test("a hyperthread sibling is not a core", () {
      // An i7-1360P: four P-cores with two threads each, then eight E-cores.
      final root = Directory.systemTemp.createTempSync("cpu").path;
      addTearDown(() => Directory(root).deleteSync(recursive: true));
      for (var cpu = 0; cpu < 16; cpu++) {
        final p = cpu < 8;
        File("$root/cpu$cpu/cpufreq/cpuinfo_max_freq")
          ..createSync(recursive: true)
          ..writeAsStringSync(p ? "5000000\n" : "3700000\n");
        File("$root/cpu$cpu/topology/thread_siblings_list")
          ..createSync(recursive: true)
          ..writeAsStringSync(p ? "${cpu & ~1}-${cpu | 1}\n" : "$cpu\n");
      }

      final ceilings = cpuCeilings(root: root, cpus: 16);

      expect(ceilings, hasLength(12));
      // The four P-cores, which is llama.cpp's own answer on x86 Linux.
      expect(bigCoreCount(ceilings), 4);
    });

    test("a kernel that will not say leaves the choice to llama.cpp", () {
      expect(bigCoreCount(const []), isNull);
      expect(launch().command, isNot(contains("-t")));
    });

    test("a count reaches the server", () {
      expect(valueOf(launch(threads: 4).command, "-t"), "4");
    });
  });

  group("persisting the KV cache", () {
    test("a slot path brings quantised KV with it", () {
      final it = launch(slotSavePath: "/cache/entoli/kv-cache");

      expect(valueOf(it.command, "--slot-save-path"), "/cache/entoli/kv-cache");
      // q8_0 halves what a dump costs on disk, and rides on the cache being on
      // so a user who turned it off keeps f16 generation.
      expect(valueOf(it.command, "-ctk"), "q8_0");
      expect(valueOf(it.command, "-ctv"), "q8_0");
    });

    test("no slot path is f16 and no save path", () {
      final it = launch();

      expect(it.command, isNot(contains("--slot-save-path")));
      expect(it.command, isNot(contains("-ctk")));
      expect(it.command, isNot(contains("-ctv")));
    });
  });

  test("the context is the model's own until something says otherwise", () {
    // Always passed, never left to llama.cpp: its `--fit` sizes the context
    // against what the CPU backend calls free memory, which on Linux is every
    // physical page — so a phone would be given a KV cache the size of its RAM.
    expect(valueOf(launch().command, "-c"), "${model.defaultContext}");
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

  group("which device a turn ends up on", () {
    const npu = LocalDevice(name: "HTP0", description: "Hexagon NPU", compute: LocalCompute.npu);
    const gpu = LocalDevice(name: "Vulkan0", description: "Mali-G715", compute: LocalCompute.gpu);

    test("auto takes the best accelerator, and the NPU beats the GPU", () {
      // The default a turn arrives with: nobody picked, so it gets the fastest
      // thing the phone has rather than the CPU it used to fall to.
      expect(resolveLocalDevice(null, [gpu, npu]), "HTP0");
      expect(resolveLocalDevice(null, [gpu]), "Vulkan0");
    });

    test("auto on a phone with no accelerator is the CPU", () {
      // `none` is ggml offloading nothing, which is the CPU — so not picking is
      // never worse than picking.
      expect(resolveLocalDevice(null, const []), noDevice);
    });

    test("the CPU can be chosen even where an accelerator exists", () {
      // Distinct from auto: the sentinel forces the slow path, which is the
      // only reason it is in the picker at all.
      expect(resolveLocalDevice(LocalDevice.cpu, [npu]), noDevice);
    });

    test("a device named outright is passed straight through", () {
      expect(resolveLocalDevice("Vulkan0", [gpu, npu]), "Vulkan0");
    });

  });

  /// A server that cannot possibly come up, over weights that are claimed to be
  /// there: `/bin/false` exits the moment it is started, which is what a real
  /// one does when the model will not fit. Real code all the way down — the
  /// process really is spawned — so this is what a machine with no Android on
  /// it can check about the pool itself.
  ///
  /// A failed load still takes its place in the pool, which is what makes the
  /// eviction order testable here: what a `serve` displaced is a property of
  /// the list, not of whether the process came up.
  group("the pool, over a server that will not start", () {
    LlamaServerPool failing() => LlamaServerPool(
          const LlamaBinaries(server: "/bin/false", libDir: "/nonexistent"),
          _AlwaysInstalled(),
        );

    Future<void> askFor(LlamaServerPool pool, String id, {int maxRunning = 1}) =>
        expectLater(
          pool.serve(id, maxRunning: maxRunning),
          throwsA(isA<LocalLlmFailure>()),
        );

    Future<void> ask(LlamaServerPool pool, LocalModel model, {int maxRunning = 1}) =>
        askFor(pool, model.id, maxRunning: maxRunning);

    test("what is waiting on it is told the server's own last words", () async {
      final pool = failing();

      await askFor(pool, model.id);

      // Not a connection to localhost that was refused, which is both true and
      // useless: for a model too big to fit, the server's own output is the
      // only place that is said.
      expect(pool.running.value.single.failure, isNotEmpty);
      expect(pool.running.value.single.phase, LocalLlmPhase.failed);
      // The failure is kept, so the settings page can draw why.
      expect(pool.running.value.single.modelId, model.id);
    });

    test("asking for a second model past the cap drops the first", () async {
      final pool = failing();

      await askFor(pool, model.id);
      await ask(pool, localModelCatalog[1]);

      expect(pool.running.value.map((each) => each.modelId),
          [localModelCatalog[1].id]);
    });

    test("raising the cap is what lets both stay", () async {
      final pool = failing();

      await askFor(pool, model.id, maxRunning: 2);
      await ask(pool, localModelCatalog[1], maxRunning: 2);

      expect(pool.running.value.map((each) => each.modelId),
          [model.id, localModelCatalog[1].id]);
    });

    test("the cap is never more than the app allows, whatever it is passed",
        () async {
      final pool = failing();

      for (final each in localModelCatalog) {
        await ask(pool, each, maxRunning: 99);
      }

      expect(pool.running.value.length, maxLocalModelsAllowed);
    });

    test("unloading everything empties the list", () async {
      final pool = failing();
      await askFor(pool, model.id, maxRunning: 2);

      await pool.stopAll();

      expect(pool.running.value, isEmpty);
    });

    test("every downloaded model is offered, not just the loaded one", () async {
      final pool = failing();

      // Nothing has been asked for, so nothing is running — and the picker is
      // full all the same. That is the whole change from the pick that used to
      // live on the settings page.
      expect(pool.running.value, isEmpty);
      expect(pool.installed, localModelCatalog.map((m) => m.id));
      expect(
          [for (final m in onDevice(pool).offered(ModelCatalog.empty, ModelHost.resolving()))
            m.ref],
          [for (final m in localModelCatalog) (providerId: localProviderId, modelId: m.id)]);
      // No address of its own: each model is its own process on its own port,
      // and the endpoint's client is what routes between them.
      expect(onDevice(pool).config.baseUrl, isEmpty);
    });

    test("a model that is not downloaded is refused before anything is spawned",
        () async {
      final pool = LlamaServerPool(
        const LlamaBinaries(server: "/bin/false", libDir: "/nonexistent"),
        const UnavailableLocalModelStore(),
      );

      await expectLater(pool.serve(model.id), throwsA(isA<LocalLlmFailure>()));

      expect(pool.running.value, isEmpty);
      // Nothing on disk is nothing to offer, which is what keeps the entry out
      // of every picker until there is something to pick.
      expect(onDevice(pool).offered(ModelCatalog.empty, ModelHost.resolving()), isEmpty);
    });

    test("a model this build has never heard of is refused too", () async {
      final pool = failing();

      await expectLater(
          pool.serve("gone-in-a-later-build"), throwsA(isA<LocalLlmFailure>()));

      expect(pool.running.value, isEmpty);
    });
  });
}

/// Says every catalog model is on disk, at a path nothing will open.
class _AlwaysInstalled extends LocalModelStore {
  const _AlwaysInstalled();

  @override
  Future<Set<String>> installed() async => const {};

  @override
  List<DownloadedModel> downloadedSync() => [
        for (final model in localModelCatalog)
          downloadedAs(model, file: "/nonexistent/${model.id}.gguf"),
      ];

  @override
  Stream<DownloadProgress> install(LocalModel model) => const Stream.empty();

  @override
  Future<void> delete(String id) async {}
}
