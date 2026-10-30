import "package:flutter/foundation.dart";
import "package:flutter_test/flutter_test.dart";

import "package:agent_chat/ui/app_licence.dart";
import "package:agent_chat/ui/theme.dart" show appTitle;

void main() {
  // About's row says "and its licence"; this is the licence it means.
  test("Entoli's own licence is on the licence page", () async {
    registerAppLicence();

    final ours = (await LicenseRegistry.licenses.toList())
        .where((l) => l.packages.contains(appTitle))
        .toList();
    expect(ours, hasLength(1));
    expect(
      ours.single.paragraphs.first.text,
      contains("GNU AFFERO GENERAL PUBLIC LICENSE"),
    );
  });
}
