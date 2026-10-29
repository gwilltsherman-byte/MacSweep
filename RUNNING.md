# Using MacSweep

If you have installed MacSweep, open **Applications > MacSweep** like any other
Mac app. Future launches do not need a build command.

## Download the app

Download the Mac build from [MacSweep for Apple silicon](https://github.com/gwilltsherman-byte/MacSweep/raw/refs/heads/main/downloads/MacSweep-AppleSilicon.zip), unzip it and move MacSweep into Applications. The Apple silicon build runs on Macs with M-series chips. Locally signed builds are not notarized by Apple, so macOS may require you to approve the first launch in Privacy & Security. A notarized release requires an Apple Developer ID certificate.

## Your saved settings

Scanning preferences and hidden items stay on your Mac when you close the app.
In Settings, use **Save a Backup** before changing Macs and **Restore a Backup**
on the other Mac. Backups do not change permissions or deletion safety. Scan
results are refreshed from the files on your Mac rather than restored as stale
file-removal targets.

## First installation from source

MacSweep requires macOS 13 or later and Xcode or Apple's Command Line Tools.
Install the tools if needed:

```sh
xcode-select --install
```

Clone the repository, build the app and open it:

```sh
git clone https://github.com/gwilltsherman-byte/MacSweep.git
cd MacSweep
./build.sh
open build/MacSweep.app
```

If you already downloaded this repository, skip the clone and enter that folder.
After building, move `build/MacSweep.app` to Applications. From then on,
double-click the app to open it.
The normal build signs it locally. You do not need an Apple Developer
subscription for this local build.

For protected folders, grant the built app Full Disk Access in System
Settings, Privacy & Security, then reopen it. Rebuilding may require granting
access again. Review selected items and the confirmation sheet before removing
files; some system commands cannot be undone.

Everything MacSweep lists, it can remove. Items that belong to the system need your
administrator password. Finder asks for it when moving them to the Trash, and macOS
asks once per removal when deleting them for good. The first time, macOS also asks
whether MacSweep may use Finder. macOS may only let MacSweep delete apps from
other developers for good once it is turned on under App Management in Privacy &
Security. Until then, MacSweep has Finder move those apps to the Trash instead.

If the app shows a blank icon after building, build it again with `./build.sh`:
the build now draws the icon before the app first runs and tells macOS about the
new copy. If Finder or the Dock still shows the old icon, run `killall Dock Finder`.

## How items are rated

Every item is rated **Safe** (rebuilt or downloaded again automatically), **Check first**
or **Careful** (may be your own data or hard to get back). After each scanner rates
its items, MacSweep checks what is actually there and only ever makes a rating more
careful. It looks for files open in a running app, folders synced with iCloud Drive,
Dropbox, Google Drive or OneDrive, files inside Git projects, Git projects that have
no remote, unsaved documents, app databases and documents inside app folders, and
whether a file was downloaded or made on this Mac. Click an item to see what it
found under **What MacSweep found**. MacSweep also leaves a duplicate in place
unless the copy it keeps is still there, unchanged and staying.

## For contributors

Run `swift test` from the repository to check the scanning and removal engine.
GitHub's Build workflow also runs tests and produces development build artifacts.

## iPhone

MacSweep has no iPhone version. It uses macOS file-system access and system
tools. Use it on your Mac.

