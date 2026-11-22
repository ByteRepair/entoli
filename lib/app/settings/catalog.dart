import "pages/general.dart";
import "pages/llms.dart";
import "pages/on_device.dart";
import "pages/prompts.dart";
import "pages/providers.dart";
import "pages/sync.dart";
import "pages/triggers.dart";
import "pages/terminal.dart";
import "schema.dart";

/// Every page's declarations, as one schema.
final entoliSettings = SettingsSchema(
  sections: [
    ...generalSections,
    ...llmSections,
    ...terminalSections,
    ...syncSections,
    ...providerSections,
    ...onDeviceSections,
    ...triggerSections,
    ...promptSections,
  ],
  settings: [
    ...generalSettings,
    ...llmSettings,
    ...terminalSettings,
    ...syncSettings,
    ...providerSettings,
    ...onDeviceSettings,
    ...triggerSettings,
    ...promptSettings,
  ],
);
