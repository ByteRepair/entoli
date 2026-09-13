// The bundled skills, written from embedded code to a real directory — a
// skill's scripts and reference files have to be somewhere a command can
// reach, and an asset key is not. The embedded data is the source of truth;
// the disk copy is a self-healed cache for bash access.
//
// Each project that ships bundled skills has its own `skills-bundled/`
// directory, beside its `skills/`. The default project's is the base set;
// another project's holds its overrides. Self-heal runs over both, so an
// edit or a stray in either is repaired on the next launch.
import "dart:convert";

import "package:crypto/crypto.dart";
import "package:flutter/foundation.dart";
import "package:fs_shim/fs.dart";

import "../../core/config.dart";
import "../../core/log.dart";
import "bundled_skill_data.dart";

/// Writes every bundled skill file from [bundledSkillFiles] into the project
/// directories it belongs to, keeping the tree. **Self-healing**: a file that
/// exists but differs from the embedded copy (by SHA-256) is re-written, so
/// an edit — accidental or deliberate — is repaired on the next launch. A
/// file not in the embedded list is deleted, so nothing an LLM left behind
/// survives.
///
/// Runs at startup, before the prompt library is built. The library reads
/// from the embedded const, not from this disk write, so even a self-heal
/// failure leaves the library correct — this is purely for bash access.
Future<void> installBundledSkills(AppConfig config) async {
  final projects = bundledSkillFiles.map((f) => f.project).toSet();
  for (final project in projects) {
    await _installFor(config, project);
  }
}

Future<void> _installFor(AppConfig config, String project) async {
  final fs = config.fs;
  final path = fs.path;
  final root = fs.directory(config.bundledSkillsDir(project: project));

  final known = <String>{};
  for (final file in bundledSkillFiles) {
    if (file.project != project) continue;
    final dest = path.join(
        config.bundledSkillsDir(project: project), file.name, file.relativePath);
    known.add(dest);
    try {
      final target = fs.file(dest);
      if (await target.exists()) {
        final onDisk = await target.readAsBytes();
        final diskHash = sha256.convert(onDisk).toString();
        if (diskHash == file.sha256) continue;
      }
      await target.create(recursive: true);
      await target.writeAsBytes(Uint8List.fromList(file.bytes));
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

/// One licence entry per bundled skill that carries its own `LICENSE.txt` —
/// the fetched ones are Anthropic's and Apache-2.0, and the notice has to
/// travel with the skill wherever it is redistributed. Read from the
/// embedded data rather than the asset bundle, and rendered by the licence
/// page About opens.
void registerBundledSkillLicences() {
  final groups = <String, String>{};
  for (final file in bundledSkillFiles) {
    if (file.relativePath != "LICENSE.txt") continue;
    groups[file.name] = utf8.decode(file.bytes);
  }
  final names = groups.keys.toList()..sort();
  LicenseRegistry.addLicense(() async* {
    for (final name in names) {
      yield LicenseEntryWithLineBreaks([name], groups[name]!);
    }
  });
}