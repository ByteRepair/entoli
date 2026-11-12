import "package:flutter/material.dart";

import "../../app/settings/spec.dart" show SettingGlyph;

/// [glyph] as this frontend draws it.
IconData? settingIcon(SettingGlyph? glyph) => switch (glyph) {
  SettingGlyph.deleteForever => Icons.delete_forever,
  SettingGlyph.play => Icons.play_circle_outline,
  SettingGlyph.stop => Icons.stop_circle_outlined,
  SettingGlyph.warning => Icons.warning_amber_rounded,
  SettingGlyph.person => Icons.person_outline,
  SettingGlyph.code => Icons.code,
  SettingGlyph.privacy => Icons.privacy_tip_outlined,
  SettingGlyph.licence => Icons.balance_outlined,
  SettingGlyph.add => Icons.add,
  SettingGlyph.download => Icons.download,
  SettingGlyph.upload => Icons.upload_file,
  SettingGlyph.notificationsOff => Icons.notifications_off_outlined,
  SettingGlyph.alarmOff => Icons.alarm_off_outlined,
  SettingGlyph.schedule => Icons.event_outlined,
  SettingGlyph.countdown => Icons.timer_outlined,
  SettingGlyph.files => Icons.description_outlined,
  SettingGlyph.online => Icons.circle,
  SettingGlyph.connecting || SettingGlyph.offline => Icons.circle_outlined,
  SettingGlyph.failed => Icons.error_outline,
  SettingGlyph.cloud => Icons.cloud_outlined,
  SettingGlyph.computer => Icons.computer,
  SettingGlyph.terminal => Icons.terminal,
  SettingGlyph.tune => Icons.tune,
  // Drawn as the app's own mark, not an icon.
  SettingGlyph.appMark || null => null,
};
