import "pages/general.dart";
import "pages/llms.dart";
import "schema.dart";

/// Every page's declarations, as one schema.
final entoliSettings = SettingsSchema(
  sections: [...generalSections, ...llmSections],
  settings: [...generalSettings, ...llmSettings],
);
