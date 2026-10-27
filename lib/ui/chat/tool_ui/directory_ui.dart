import "package:flutter/material.dart";

import "../../../domain/permission.dart";
import "tool_ui.dart";

/// The directory grant: its banner is the whole grant.
class AddDirectoryUI extends ToolUI {
  const AddDirectoryUI();

  @override
  String get tool => addDirectoryName;

  @override
  (IconData, String) get approval =>
      (Icons.create_new_folder_outlined, "Let the agent write here?");
}
