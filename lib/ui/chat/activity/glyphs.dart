import "package:flutter/material.dart";

import "../../../app/transcript/activity.dart" show TranscriptGlyph;

/// The Material icon each of the conversation's glyphs is drawn as here.
IconData iconOf(TranscriptGlyph glyph) => switch (glyph) {
  TranscriptGlyph.terminal => Icons.terminal,
  TranscriptGlyph.thinking => Icons.psychology_outlined,
  TranscriptGlyph.file => Icons.description_outlined,
  TranscriptGlyph.edit => Icons.edit_outlined,
  TranscriptGlyph.search => Icons.travel_explore_outlined,
  TranscriptGlyph.web => Icons.language_outlined,
  TranscriptGlyph.subAgent => Icons.account_tree_outlined,
  TranscriptGlyph.question => Icons.help_outline,
  TranscriptGlyph.permissionGranted => Icons.gpp_good_outlined,
  TranscriptGlyph.permissionDenied => Icons.gpp_maybe_outlined,
  TranscriptGlyph.plan => Icons.checklist,
  TranscriptGlyph.artifact => Icons.insert_chart_outlined,
  TranscriptGlyph.skill => Icons.extension,
  TranscriptGlyph.folderAdd => Icons.create_new_folder_outlined,
  TranscriptGlyph.shield => Icons.shield_outlined,
  TranscriptGlyph.error => Icons.error_outline,
  TranscriptGlyph.goalActive => Icons.track_changes,
  TranscriptGlyph.goalPaused => Icons.pause_circle_outline,
  TranscriptGlyph.goalMet => Icons.check_circle_outline,
  TranscriptGlyph.goalBlocked => Icons.block,
  TranscriptGlyph.goalResumed => Icons.play_circle_outline,
  TranscriptGlyph.goalCleared => Icons.highlight_off,
  TranscriptGlyph.info => Icons.info_outline,
};
