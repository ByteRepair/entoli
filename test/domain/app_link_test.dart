import "dart:convert";
import "dart:typed_data";

import "package:agent_chat/domain/app_link.dart";
import "package:archive/archive.dart";
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
    const at = "entoli://install/marketplace/entoli";
    final skill = _parse("$at/skill/pdf")! as InstallLink;
    expect((skill.kind, skill.slug), (CompletionKind.skill, "pdf"));
    final agent = _parse("$at/agent/owner/reviewer")!;
    expect((agent as InstallLink).slug, "owner/reviewer");
  });

  final prompt = utf8.encode("---\ndescription: d\n---\nKeep a diary.");
  final skill = Uint8List.fromList(
    ZipEncoder().encode(
      Archive()..addFile(
        ArchiveFile.bytes("s/SKILL.md", utf8.encode("---\nname: s\n---\nx")),
      ),
    ),
  );

  test("a shared entry comes back as it was shared", () {
    final agent =
        _parse(AppLink.share(CompletionKind.agent, "diary", prompt))!
            as SharedEntryLink;
    expect((agent.kind, agent.name), (CompletionKind.agent, "diary"));
    expect(agent.bytes, prompt);
    final shared =
        _parse(AppLink.share(CompletionKind.skill, "s", skill))!
            as SharedEntryLink;
    expect(shared.bytes, skill);
  });

  test("a shared entry cut short anywhere carries nothing", () {
    for (final (kind, bytes) in [
      (CompletionKind.agent, prompt),
      (CompletionKind.skill, skill),
    ]) {
      final link = AppLink.share(kind, "x", bytes);
      final start = link.indexOf("def=") + 5;
      for (var end = start; end < link.length; end++) {
        final cut = _parse(link.substring(0, end))! as SharedEntryLink;
        expect(cut.bytes, isNull, reason: "$kind cut at $end");
      }
    }
    // Plain text says nothing about whether it all arrived, so it is refused.
    final plain = base64Url.encode(prompt);
    final link = _parse("entoli://install/agent?name=x&def=$plain")!;
    expect((link as SharedEntryLink).bytes, isNull);
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
      "entoli://install/skill/pdf",
      "entoli://install/marketplace/other/skill/pdf",
      "entoli://delete",
    ]) {
      expect(_parse(s), isNull, reason: s);
    }
  });
}
