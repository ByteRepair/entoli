import "pages/about.dart";
import "pages/browser.dart";
import "pages/general.dart";
import "pages/llms.dart";
import "pages/memory.dart";
import "pages/sync.dart";
import "pages/terminal.dart";
import "pages/voice.dart";
import "schema.dart";

/// Every page's declarations, as one schema.
final entoliSettings = SettingsSchema(
  sections: [
    ...generalSections,
    ...llmSections,
    ...memorySections,
    ...voiceSections,
    ...terminalSections,
    ...browserSections,
    ...aboutSections,
    ...syncSections,
  ],
  settings: [
    ...generalSettings,
    ...llmSettings,
    ...memorySettings,
    ...voiceSettings,
    ...terminalSettings,
    ...browserSettings,
    ...aboutSettings,
    ...syncSettings,
  ],
);
