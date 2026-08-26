// The bundled skills, copied out of the asset bundle to a real directory —
// a skill's scripts and reference files have to be somewhere a command can
// reach, and an asset key is not.
import "package:flutter/foundation.dart";
import "package:flutter/services.dart";

import "../../core/config.dart";
import "../../core/log.dart";

/// Copies every file packaged under `assets/prompts/skills/` into
/// `<dataDir>/skills-bundled/`, keeping the tree. **Copy-if-absent**: an
/// extracted file is never overwritten, so an update reaches a fresh install
/// and a user's edit of their extracted copy is theirs to keep.
///
/// Runs at startup, before the prompt library is built, so the sources read
/// what this wrote. A file that fails to copy costs its skill's scripts, not
/// the skill's instructions — the `SKILL.md` is small and first in the tree —
/// and either way the failure gets a line and the app carries on.
Future<void> installBundledSkills(AppConfig config, {AssetBundle? bundle}) async {
  final assets = bundle ?? rootBundle;
  final manifest = await AssetManifest.loadFromAssetBundle(assets);
  for (final key in manifest.listAssets()) {
    if (!key.startsWith("assets/prompts/skills/")) continue;
    final relative = key.substring("assets/prompts/skills/".length);
    if (relative.isEmpty) continue;
    final destination = config.fs.path.join(config.bundledSkillsDir, relative);
    final file = config.fs.file(destination);
    try {
      if (await file.exists()) continue;
      await file.create(recursive: true);
      await file.writeAsBytes(await _readAsset(assets, key));
    } catch (e) {
      logFailure("skills", "could not extract $relative", e);
    }
  }
}

/// A file in the bundle is bytes, not a string — a skill carries scripts and
/// HTML beside its markdown.
Future<Uint8List> _readAsset(AssetBundle assets, String key) async {
  final data = await assets.load(key);
  final bytes = Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
  // Copied rather than handed over: the buffer behind an asset load can be
  // reused once the caller returns.
  return Uint8List.fromList(bytes);
}

/// The licence of the bundled skill-creator, which is Apache-2.0 and carries
/// its own copy in the tree. Not platform-gated the way the voice ones are:
/// a skill is bundled on every platform, and so is its licence.
void registerBundledSkillLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ["skill-creator"],
      await rootBundle.loadString("assets/prompts/skills/skill-creator/LICENSE.txt"),
    );
  });
}
