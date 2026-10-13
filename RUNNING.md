# Using MacSweep

If you have installed MacSweep, open **Applications > MacSweep** like any other
Mac app. Future launches do not need a build command.

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

## For contributors

Run `swift test` from the repository to check the scanning and removal engine.
GitHub's Build workflow also runs tests and produces development build artifacts.

## iPhone

MacSweep has no iPhone version. It uses macOS file-system access and system
tools. Use it on your Mac.

