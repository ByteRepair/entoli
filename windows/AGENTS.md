# Windows

`flutter build windows` produces a directory that moves together — the exe
resolves flutter_windows.dll and the plugin DLLs beside itself and finds the
Dart assets in `data\` beside those — and the installer is what turns it into
one file. The runner is Flutter's generated template
(`flutter create --platforms=windows`, runnable on any host), with the two
names it hardcodes changed: `BINARY_NAME "entoli"` in `windows/CMakeLists.txt`
is what makes the build `entoli.exe` — the app's name, not the package's, the
name the release assets carry — and `main.cpp`'s `window.Create(L"Entoli")`
with `Runner.rc`'s strings say Entoli everywhere else a user looks at a name.

This platform does not run on the Mac the rest of the work happens on: the
build and the installer are CI's (`release-build.yml`'s `windows` job,
`windows-latest`), and any change to either is a push and a run. The runner
image carries Visual Studio and the .NET SDK, so neither needs installing;
the job is `./.github/actions/flutter-setup`, a `flutter build windows`, and
the packaging script — every job that touches Dart sharing the same setup.

## The MSI

The packaging is `tool/windows/make-msi.ps1`, not a workflow step, and it
takes a bundle and an output path, the way `make-appimage.sh` and
`make-dmg.sh` do — plus one thing their signatures lack, `-Version`, the
number the package reports to Add/Remove Programs and what a later installer
installs over: pubspec stays the version job's to read, and the script
refuses a bundle with no `entoli.exe` in it.

`tool/windows/entoli.wxs` is the authoring. `Files Include="$(BundlePath)\**"`
harvests the bundle whole (the exe, the DLLs, `data\` and whatever a later
build adds to the directory), into `ProgramFiles6432Folder\Entoli` — Program
Files on an x64 machine, and the shortcut targets `[INSTALLFOLDER]entoli.exe`
there. `BundlePath` is the absolute path make-msi.ps1 resolves the bundle to,
the fully-qualified pattern the WiX docs recommend over a relative one: a
relative pattern over a bind path resolved to nothing once, and WIX8600
grades a zero-file harvest a warning the build would have shipped green.
The tripwire after it is that failure's: the MSI must carry `entoli.exe` as
a File row or make-msi.ps1 throws. The cabinet embeds (`MediaTemplate
EmbedCab="yes"`): an external one is a second file beside the MSI, present
where it was built and gone when a release carries the MSI alone — the size
check is that regression's tripwire.

**What an uninstall removes and what it keeps.** The installer removes what
its tables hold: the Program Files folder, the Start Menu shortcut, the key
path in `HKLM\Software\ByteRepair\Entoli` — and it keeps everything the app
made while running, all of it outside the tables: the data directory and the
voice cache survive it, the way an update does. A release that moves
anything under the data directory answers by a migration instead. The
**UpgradeCode is the identity of every install to come**: an installer built
later finds this one and replaces it, one built sooner refuses in its name's
sake, and one carrying a different UpgradeCode is a different app Windows
uninstalls beside, not over — it is never re-generated, like the Android
keystore, and neither is the shortcut component's GUID below: the two are
every GUID `entoli.wxs` holds. The shortcut component
keys on a registry value under `Software\ByteRepair\Entoli` in HKLM, the
key path being what a component that installs no file keys on. WiX 7 is the
dotnet tool the script installs, pinned, and its EULA is accepted per
invocation: the Open Source Maintenance Fee is an organization's to pay, not
an open-source release's.

## The icon

`tool/windows/make-ico.py` renders `windows/runner/resources/app_icon.ico`
from `web/icons/Icon-512.png` — the default icon already rendered, the same
PWA image the AppImage installs by — with the stdlib alone, no Pillow and no
package manager: it decodes the PNG, box-averages down to seven sizes, and
writes the BMP layers an ICO has carried since forever. One file is both the
exe's icon and the window's, `Runner.rc` binding the ico by name.

## What is absent, and honestly so

**No model server.** The build is like macOS's: `platformLocalLlm` answers
`UnavailableLocalLlm` here, and the On-device page says what that is worth; a
`llama-server` for Windows is native work not started. **The shell is the
machine's own.** No rootfs, no proot, no bundled git: commands run with what
the machine has, and where a Linux command would be parsed, Windows commands
are escalated, not parsed. Byte Repair's setup rides the bash that exists —
Git-for-Windows' — and fetches `esbmc-windows.zip` into the app's cache
there, its exec carried by `.exe` and the Expand-Archive fallback its
extraction chain reaches for. **The data directory is
`%USERPROFILE%\.config\agent-chat`**, the desktop default's shape — the
cache's `%LOCALAPPDATA%\agent-chat\Cache`, and `$AGENT_CHAT_CONFIG` over
both. **Nothing signs it.** Like the DMG, the first run of both the installer
and the app goes through SmartScreen's Run anyway until a code-signing
certificate exists; the MSI's signing and the DMG's grow together. **The
dialogs are WixUI_Minimal's.** One welcome screen carrying the AGPL off the
repo's `LICENSE` — the Install button that follows it is where the user
commits — then the progress and the finish; what is absent from it is
WixUI_InstallDir's directory-choosing page, the install being to Program
Files and nowhere else a person sets.

## Self-update

A running exe cannot be renamed under itself, so the update is the MSI run:
at startup the app downloads `entoli-installer.msi` into the cache and arms a
detached PowerShell that waits for this process to exit, then runs
`msiexec /i <that msi> /qn /norestart`. The installer's own elevation prompt
is what the user answers on the way out; the next start is the upgraded
install, reached through the same UpgradeCode and so this installer replacing
its own prior work. See "The automatic update" in the root notes.