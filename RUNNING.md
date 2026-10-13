# Run MacSweep

## Mac

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

The app is in `build/MacSweep.app`; you can move it to Applications.
The normal build signs it locally. You do not need an Apple Developer
subscription for this local build.

For protected folders, grant the built app Full Disk Access in System
Settings, Privacy & Security, then reopen it. Rebuilding may require granting
access again. Review selected items and the confirmation sheet before removing
files; some system commands cannot be undone.

Run `swift test` from the repository to check the scanning and removal engine.
GitHub's Build workflow also runs tests and produces development build artifacts.

## iPhone

MacSweep has no iPhone version. It uses macOS file-system access and system
tools, so GitHub Pages cannot turn it into an iPhone app. Use it on your Mac.
