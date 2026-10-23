import "package:agent_chat/data/builtin/templates.dart";
import "package:flutter_test/flutter_test.dart";

void main() {
  test("points temporary files at the chat's .entoli-tmp, not /tmp", () {
    final prompt = turnPrompt(
      workspace: "/w/chats/c",
      projectWorkspace: "/w",
      canRunCommands: true,
      projectHome: false,
    );
    expect(prompt, contains("/w/chats/c/.entoli-tmp"));
    expect(prompt, contains("never in `/tmp`"));
  });
}
