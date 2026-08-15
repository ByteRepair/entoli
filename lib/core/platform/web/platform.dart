import "../../../data/local/memory_chat_store.dart";
import "../../../data/local/memory_storage.dart";
import "../../../data/prompts/prompt_sources.dart";
import "../../../domain/chat_store.dart";
import "../../../domain/prompt_library.dart";
import "../../../domain/shell.dart";
import "../../../domain/storage.dart";
import "../../../domain/web_search.dart";
import "../../config.dart";

Shell platformShell({required Map<String, String> Function() environment}) =>
    const UnavailableShell();

WebSearch platformWebSearch() => const UnavailableWebSearch();

Storage platformStorage() => MemoryStorage();

ChatStore platformChatStore(AppConfig config) => MemoryChatStore();

/// Only the presets: there is no directory a browser could have put a prompt
/// file in.
List<PromptSource> platformPromptSources(AppConfig config) => [const BundledPrompts()];

String? processEnv(String name) => null;
