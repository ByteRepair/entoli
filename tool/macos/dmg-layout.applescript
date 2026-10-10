on run argv
  -- The one styling pass that feeds tool/macos/dmg-window.dsstore: attaches
  -- nothing itself; make-dmg.sh is not this file's caller — the capture
  -- recipe in macos/AGENTS.md runs it against the attached UDRW, and what
  -- Finder writes to the volume's .DS_Store is what gets committed.
  set vol to item 1 of argv
  set appName to item 2 of argv
  set W to (item 3 of argv) as number
  set Hwin to (item 4 of argv) as number
  set wx to (item 5 of argv) as number
  set wy to (item 6 of argv) as number
  set appPos to (item 7 of argv) as number
  set appsPos to (item 8 of argv) as number
  set rowPos to (item 9 of argv) as number
  set iconSize to (item 10 of argv) as number
  tell application "Finder"
    tell disk vol
      open
      set current view of container window to icon view
      set theViewOptions to the icon view options of container window
      set arrangement of theViewOptions to not arranged
      set icon size of theViewOptions to iconSize
      set background picture of theViewOptions to file ".background:background.tiff"
      set bounds of container window to {wx, wy, wx + W, wy + Hwin}
      set position of item appName of container window to {appPos, rowPos}
      set position of item "Applications" of container window to {appsPos, rowPos}
      try
        set theToolbar to toolbar of container window
        set statusbar of theToolbar to false
      end try
      close
      open
      update without registering applications
    end tell
  end tell
end run