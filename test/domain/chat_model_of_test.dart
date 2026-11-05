import "package:agent_chat/domain/app_settings.dart";
import "package:agent_chat/domain/chat_meta.dart";
import "package:agent_chat/domain/chat_repository.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  final settings = AppSettings(
    defaultProviderId: "app",
    defaultModelId: "app-model",
  );

  test("a chat with no choice runs on the app default", () {
    expect(chatModelOf(ChatMeta(), settings), (
      modelId: "app-model",
      providerId: "app",
    ));
  });

  test("a chat's own model runs under its own provider", () {
    expect(chatModelOf(ChatMeta(provider: "cli", model: "opus"), settings), (
      modelId: "opus",
      providerId: "cli",
    ));
  });

  test(
    "a provider's Default entry keeps the provider, its default to come",
    () {
      expect(chatModelOf(ChatMeta(provider: "cli"), settings), (
        modelId: null,
        providerId: "cli",
      ));
    },
  );
}
