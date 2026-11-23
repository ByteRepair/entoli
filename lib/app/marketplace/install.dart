import "dart:typed_data";

import "package:flutter_riverpod/misc.dart" show ProviderListenable;
import "package:entoli_core/model/log.dart";
import "package:entoli_core/model/agent_face.dart";
import "package:entoli_core/store/prompts/skill_import.dart";

import "../../providers.dart";
import "../prompts/agent_files.dart";
import "../prompts/own_prompts.dart";
import "../prompts/skill_files.dart";

/// What an install asks before it replaces something already there.
typedef ReplaceQuestion = ({String title, String message});

/// An install from outside the app's own pages (a marketplace entry, a
/// shared link, a skill a turn drafted) into [target], Global where null.
/// Every route asks the same replace question and lands the same way, the
/// libraries read again after.
class PromptInstall {
  const PromptInstall(this.read, {this.target});

  final T Function<T>(ProviderListenable<T> provider) read;
  final String? target;

  /// [doing] is how the question names the write.
  ReplaceQuestion? replacingSkill(
    SkillPackage package, {
    String doing = "Installing",
  }) => SkillFiles(read(appConfigProvider)).has(package.name, target: target)
      ? (
          title: "Replace ${package.name}?",
          message:
              "A skill with that name is already installed there. $doing "
              "this one replaces it, files included.",
        )
      : null;

  /// Returns what to say once it has landed.
  Future<String> skill(SkillPackage package) async {
    await SkillFiles(read(appConfigProvider)).install(package, target: target);
    await read(promptChangesProvider).reload(target);
    return installedSnack("Installed", package.name, target);
  }

  /// Why an agent cannot be installed as [name], or null where it can.
  static String? agentRefusal(String name) => isFolderName(name)
      ? null
      : "This agent cannot be installed: its name cannot be a file name.";

  ReplaceQuestion? replacingAgent(String name, {String doing = "Installing"}) =>
      AgentFiles(read(appConfigProvider), project: target).has(name)
      ? (
          title: "Replace $name?",
          message:
              "An agent with that name is already installed. $doing this "
              "one replaces it.",
        )
      : null;

  /// [source] as [name], with [picture] as its face or none, so an agent
  /// installed over another does not keep the face of the one it replaced.
  /// Returns what to say once it has landed.
  Future<String> agent(String name, String source, {Uint8List? picture}) async {
    await AgentFiles(
      read(appConfigProvider),
      project: target,
    ).write(name, source, face: picture == null ? null : AgentPhoto(picture));
    await read(promptChangesProvider).reload(target);
    return installedSnack("Installed", name, target);
  }
}

/// The skill a turn drafted and packaged, or null where it cannot be read:
/// deleted with its chat, or not a package.
Future<SkillPackage?> readDraftedSkill(
  T Function<T>(ProviderListenable<T> provider) read,
  String chatId,
  String installId,
) async {
  try {
    final bytes = await read(
      chatStoreProvider,
    ).readSkillInstall(chatId, installId);
    return bytes == null ? null : parseSkillPackage(bytes);
  } catch (e) {
    logFailure("skills", "could not read drafted skill $installId", e);
    return null;
  }
}
