import "dart:io";

import "../../../data/local/local_chat_store.dart";
import "../../../data/miniswe/duckduckgo_search.dart";
import "../../../data/miniswe/local_shell.dart";
import "../../../data/prompts/prompt_sources.dart";
import "../../../domain/chat_store.dart";
import "../../../domain/prompt_library.dart";
import "../../../domain/shell.dart";
import "../../../domain/web_search.dart";
import "../../config.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    LocalShell(environment: environment);

WebSearch platformWebSearch() => DuckDuckGoSearch();

ChatStore platformChatStore(AppConfig config) => LocalChatStore(config);

/// The user's own come last: a file they wrote replaces the preset it shares a
/// name with.
List<PromptSource> platformPromptSources(AppConfig config) =>
    [const BundledPrompts(), DirectoryPrompts(config)];

String? processEnv(String name) => Platform.environment[name];
