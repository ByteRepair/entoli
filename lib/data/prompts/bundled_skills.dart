// The bundled skills, written from embedded code to a real directory — a
// skill's scripts and reference files have to be somewhere a command can
// reach, and an asset key is not. The embedded data is the source of truth;
// the disk copy is a self-healed cache for bash access.
import "dart:convert";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "bundled_skill_data.dart";

/// Writes every bundled skill file from [bundledSkillFiles] into
/// `<dataDir>/skills-bundled/`, keeping the tree. **Self-healing**: a file that
/// exists but differs from the embedded copy (by SHA-256) is re-written, so an
/// edit — accidental or deliberate — is repaired on the next launch. A file not
/// in the embedded list is deleted, so nothing an LLM left behind survives.
///
/// Runs at startup, before the prompt library is built. The library reads from
/// the embedded const, not from this disk write, so even a self-heal failure
/// leaves the library correct — this is purely for bash access.
Future<void> installBundledSkills(AppConfig config) async {
  final fs = config.fs;
  final path = fs.path;
  final root = fs.directory(config.bundledSkillsDir);

  final known = <String>{};
  for (final file in bundledSkillFiles) {
    final dest = path.join(config.bundledSkillsDir, file.name, file.relativePath);
    known.add(dest);
    try {
      final target = fs.file(dest);
      if (await target.exists()) {
        final onDisk = await target.readAsString();
        final diskHash = sha256.convert(utf8.encode(onDisk)).toString();
        if (diskHash == file.sha256) continue;
      }
      await target.create(recursive: true);
      await target.writeAsString(file.content);
    } catch (e) {
      logFailure("skills", "could not write ${file.name}/${file.relativePath}", e);
    }
  }

  if (await root.exists()) {
    await _deleteStrays(fs, root, known);
  }
}

Future<void> _deleteStrays(
    FileSystem fs, Directory dir, Set<String> known) async {
  final entities = await dir.list().toList();
  for (final entity in entities) {
    if (entity is File) {
      if (!known.contains(entity.path)) {
        try {
          await entity.delete();
        } catch (e) {
          logFailure("skills", "could not delete stray ${entity.path}", e);
        }
      }
    } else if (entity is Directory) {
      await _deleteStrays(fs, entity, known);
      try {
        final remaining = await entity.list().toList();
        if (remaining.isEmpty) await entity.delete();
      } catch (_) {}
    }
  }
}

/// The licence of the bundled skill-creator, which is Apache-2.0 and carries
/// its own copy in the tree. Read from the embedded data rather than the asset
/// bundle.
void registerBundledSkillLicences() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ["skill-creator"],
      bundledSkillLicence,
    );
  });
}