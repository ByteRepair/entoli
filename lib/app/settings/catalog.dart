import "pages/about.dart";
import "pages/browser.dart";
import "pages/byte_repair.dart";
import "pages/data.dart";
import "pages/general.dart";
import "pages/llms.dart";
import "pages/memory.dart";
import "pages/on_device.dart";
import "pages/providers.dart";
import "pages/sync.dart";
import "pages/triggers.dart";
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
    ...dataSections,
    ...providerSections,
    ...onDeviceSections,
    ...byteRepairSections,
    ...triggerSections,
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
    ...dataSettings,
    ...providerSettings,
    ...onDeviceSettings,
    ...byteRepairSettings,
    ...triggerSettings,
  ],
);
