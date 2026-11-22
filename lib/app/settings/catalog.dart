import "pages/general.dart";
import "pages/llms.dart";
import "pages/prompts.dart";
import "pages/terminal.dart";
import "schema.dart";

/// Every page's declarations, as one schema.
final entoliSettings = SettingsSchema(
  sections: [
    ...generalSections,
    ...llmSections,
    ...terminalSections,
    ...promptSections,
  ],
  settings: [
    ...generalSettings,
    ...llmSettings,
    ...terminalSettings,
    ...promptSettings,
  ],
);
