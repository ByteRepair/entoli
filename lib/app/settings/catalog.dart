import "pages/general.dart";
import "pages/llms.dart";
import "pages/memory.dart";
import "schema.dart";

/// Every page's declarations, as one schema.
final entoliSettings = SettingsSchema(
  sections: [...generalSections, ...llmSections, ...memorySections],
  settings: [...generalSettings, ...llmSettings, ...memorySettings],
);
