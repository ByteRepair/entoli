import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/data/routing_backend.dart";
import "package:agent_chat/domain/models.dart";

import "../fakes.dart";

void main() {
  late FakeBackend opencode;
  late FakeBackend miniswe;
  late Map<String, BackendKind> onDisk;
  late BackendKind fallback;

  setUp(() {
    opencode = FakeBackend();
    miniswe = FakeBackend()..kindOverride = BackendKind.miniswe;
    onDisk = {};
    fallback = BackendKind.opencode;
  });

  RoutingBackend routerOver() => RoutingBackend(
        backends: {BackendKind.opencode: opencode, BackendKind.miniswe: miniswe},
        defaultKind: () => fallback,
        kindOf: (chatId) => onDisk[chatId],
      );

  test("a chat goes to the backend it was created with", () async {
    onDisk["old-opencode"] = BackendKind.opencode;
    onDisk["old-miniswe"] = BackendKind.miniswe;
    final router = routerOver();

    await router.sendPrompt("old-opencode", "one").toList();
    await router.sendPrompt("old-miniswe", "two").toList();

    expect(opencode.prompts.map((p) => p.text), ["one"]);
    expect(miniswe.prompts.map((p) => p.text), ["two"]);
  });

  test("retargeting the default leaves existing chats where they are", () async {
    onDisk["existing"] = BackendKind.opencode;
    final router = routerOver();
    fallback = BackendKind.miniswe;

    await router.sendPrompt("existing", "still opencode").toList();

    expect(opencode.prompts, hasLength(1));
    expect(miniswe.prompts, isEmpty);
  });

  test("a new chat is created on the default and stays there", () async {
    fallback = BackendKind.miniswe;
    final router = routerOver();

    final chat = await router.createChat(title: "fresh");
    await router.sendPrompt(chat.state.id, "hello").toList();

    expect(chat.state.backend, BackendKind.miniswe);
    expect(miniswe.prompts.map((p) => p.text), ["hello"]);
    expect(opencode.prompts, isEmpty);
  });

  test("a chat nothing knows about falls back to the default", () async {
    final router = routerOver();

    await router.sendPrompt("unknown", "hi").toList();

    expect(opencode.prompts, hasLength(1));
  });

  test("how long to wait comes from the backend actually running it", () async {
    onDisk["mini"] = BackendKind.miniswe;
    miniswe.stall = const Duration(minutes: 3);
    final router = routerOver();

    expect(router.stallTimeout("mini"), const Duration(minutes: 3));
    expect(router.stallTimeout("other"), opencode.stallTimeout("other"));
  });

  test("whether approvals mean anything is the chat's backend's answer", () async {
    onDisk["mini"] = BackendKind.miniswe;
    onDisk["oc"] = BackendKind.opencode;
    opencode.honours = false;
    final router = routerOver();

    expect(router.honoursApprovals("mini"), isTrue);
    expect(router.honoursApprovals("oc"), isFalse);
  });

  test("aborting, resetting and approving all follow the same route", () async {
    onDisk["mini"] = BackendKind.miniswe;
    final router = routerOver();

    await router.abort("mini");
    await router.resetSession("mini");
    await router.respondApproval("mini", "a1", ApprovalResponse.allow);

    expect(miniswe.aborted, ["mini"]);
    expect(miniswe.resets, hasLength(1));
    expect(opencode.aborted, isEmpty);
  });

  test("shutting down stops every backend, not just the one in use", () async {
    await routerOver().shutdown();

    expect(opencode.didShutdown, isTrue);
    expect(miniswe.didShutdown, isTrue);
  });

  test("the model list is the union, the default's first", () async {
    opencode.modelList = const [
      ModelOption(providerId: "anthropic", modelId: "claude-x"),
      ModelOption(providerId: "openai", modelId: "gpt-x"),
    ];
    miniswe.modelList = const [
      // The same pair from both is one entry: a model either can run should
      // not be offered twice.
      ModelOption(providerId: "anthropic", modelId: "claude-x"),
      ModelOption(providerId: "ollama-cloud", modelId: "kimi"),
    ];

    final models = await routerOver().models();

    expect(models.map((m) => "${m.providerId}/${m.modelId}"),
        ["anthropic/claude-x", "openai/gpt-x", "ollama-cloud/kimi"]);
  });

  test("disposing a chat sends it to its own backend and forgets the route", () async {
    onDisk["mini"] = BackendKind.miniswe;
    final router = routerOver();

    await router.sendPrompt("mini", "hi").toList();
    await router.disposeChat("mini");
    // The chat is gone from disk too, so the next mention of the id is a new
    // chat on whatever the default now is.
    onDisk.remove("mini");
    fallback = BackendKind.opencode;
    await router.sendPrompt("mini", "again").toList();

    expect(miniswe.prompts, hasLength(1));
    expect(opencode.prompts, hasLength(1));
  });
}
