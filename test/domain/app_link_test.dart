import "dart:convert";

import "package:agent_chat/domain/app_link.dart";
import "package:agent_chat/domain/bot_avatar/import.dart";
import "package:agent_chat/domain/models.dart";
import "package:flutter_test/flutter_test.dart";

const _box =
    '{"version":1,"id":"box","name":"Box","body":{"path":"M20 20 H80 V80 H20 Z"},'
    '"eyes":{"x":50,"y":46,"spacing":15,"scale":1}}';

AppLink? _parse(String s) => AppLink.parse(Uri.parse(s));

void main() {
  test("a harness link is a new chat with its prompt", () {
    final prompt = "Fetch https://x/prompt.md\n\nMake a cat & a hat";
    final link = _parse("entoli://new?prompt=${Uri.encodeComponent(prompt)}");
    expect((link! as NewChatLink).prompt, prompt);
  });

  test("a marketplace link names its kind and slug, slashes and all", () {
    final skill = _parse("entoli://install/skill/pdf")! as InstallLink;
    expect((skill.kind, skill.slug), (CompletionKind.skill, "pdf"));
    final agent = _parse("entoli://install/agent/owner/reviewer")!;
    expect((agent as InstallLink).slug, "owner/reviewer");
  });

  test("an avatar link takes raw or base64url JSON", () {
    for (final def in [
      Uri.encodeComponent(_box),
      base64Url.encode(utf8.encode(_box)).replaceAll("=", ""),
    ]) {
      final link = _parse("entoli://install/avatar?def=$def")! as AvatarLink;
      final imported = link.import as BotAvatarImported;
      expect(imported.definitions.single.id, "box");
    }
  });

  test("anything else is not a link", () {
    for (final s in [
      "https://new?prompt=x",
      "entoli://install/avatar",
      "entoli://install/widget/x",
      "entoli://install/skill",
      "entoli://delete",
    ]) {
      expect(_parse(s), isNull, reason: s);
    }
  });
}
