import "package:entoli_glass/entoli_glass.dart" show Glyph;
import "package:flutter/material.dart";

import "../../domain/project.dart" show projectIcon;

/// What one of the Flutter frontend's Material icons stands for, for the
/// native shell to draw in its own; null where the shell has nothing to
/// stand for it, which then words the item instead.
Glyph? glyphOf(IconData? icon) => icon == null ? null : _glyphs[icon];

final Map<IconData, Glyph> _glyphs = {
  Icons.add: Glyph.add,
  Icons.check: Glyph.check,
  Icons.checklist: Glyph.checklist,
  Icons.close: Glyph.close,
  Icons.copy: Glyph.copy,
  Icons.copy_all_outlined: Glyph.copy,
  Icons.create_new_folder_outlined: Glyph.newFolder,
  Icons.delete_outline: Glyph.delete,
  Icons.edit_outlined: Glyph.edit,
  Icons.filter_list: Glyph.filter,
  Icons.format_size: Glyph.textSize,
  Icons.open_in_browser: Glyph.openInBrowser,
  Icons.open_in_new: Glyph.openExternal,
  Icons.restart_alt: Glyph.restart,
  Icons.save_outlined: Glyph.save,
  Icons.visibility_outlined: Glyph.show,
  Icons.visibility_off: Glyph.hidden,
  Icons.terminal: Glyph.terminal,
  Icons.public: Glyph.globe,
  Icons.travel_explore: Glyph.browse,
  Icons.description_outlined: Glyph.document,
  Icons.shield_outlined: Glyph.shield,
  Icons.verified_user: Glyph.shield,
  Icons.groups: Glyph.team,
};

/// What [project] is drawn as: a built-in's own, else home for the default
/// and a folder for the rest.
Glyph projectShellGlyph(String? project) =>
    glyphOf(projectIcon(project)) ??
    (project == null ? Glyph.home : Glyph.folder);
