# MacSweep

A native macOS app that finds everything on your Mac that might be unnecessary
and lets you look through it and remove what you don't want.

Nothing is removed until you tick it and confirm. Every item has a rating
(**Safe**, **Review** or **Caution**), a note saying what it is and what
removing it does, and a "Show exactly what will happen" list of the actual
operations. Files go to the Trash by default.

## What it looks for

**System junk**
- User caches (`~/Library/Caches`) and system caches (`/Library/Caches`)
- Hidden app caches: sandboxed app caches, and the Chromium/Electron caches
  (Slack, Discord, Teams, Chrome, VS Code…) kept in Application Support
- Command-line tool caches (`~/.cache`)
- Logs, crash reports, rotated system logs and core dumps (`/cores`)
- Temporary files, per-user system caches, Quick Look thumbnails, font caches
- Saved window state
- The Trash, on every drive
- Time Machine local snapshots

**Apps & add-ons**
- Every app in `/Applications` and `~/Applications`, with when you last used
  it. Removing an app also removes its settings, containers, caches, cookies,
  launch agents and so on. Homebrew-installed apps are uninstalled through
  Homebrew.
- App leftovers: preferences, containers, group containers and support
  folders whose app is no longer installed
- Login items, launch agents and launch daemons, with broken ones flagged
- Privileged helper tools
- Plug-ins and drivers: Audio Units, VST/VST3/CLAP/AAX, Quick Look, Spotlight,
  settings panes, screen savers, input methods, services, kernel extensions,
  file system drivers, printer and scanner drivers, and more
- Fonts you installed, grouped by family
- Software installed with `.pkg` installers, removable file by file using the
  installer's own receipt (and receipts for software that's already gone)
- GarageBand and Logic sound libraries, macOS upgrade leftovers, extra dictionaries
- Steam and Epic games, Steam caches

**Developer**
- Homebrew packages (unused dependencies are marked Safe, and anything other
  packages need is marked Caution), Homebrew casks, old versions and
  downloads (`brew cleanup`), and taps you don't use
- MacPorts ports, inactive versions and build leftovers
- Project build folders anywhere in your home folder: `node_modules`, Rust
  `target`, Swift `.build`, Gradle `build`, `.next`, `Pods`, Python virtual
  environments, `__pycache__`, `.terraform`, `zig-cache`, Lightroom previews…
- Xcode: DerivedData per project, archives, device support files, simulators
  (unavailable ones are marked Safe), simulator runtimes, previews and caches
- Node.js: global npm packages, Node versions from nvm/fnm/volta/n/nodenv,
  npm/pnpm/Yarn/Bun caches
- Python: pyenv/uv/python.org versions, virtualenvs, pipenv and conda
  environments, conda package caches, pipx tools, `pip --user` packages
- Ruby, Rust (toolchains, Cargo caches, `cargo install` tools), Go (module
  cache, `go install` tools, extra Go versions)
- Java, Kotlin & Android: Gradle and Maven caches, JDKs, SDKMAN, Android SDK
  platforms, build-tools, NDKs, system images and emulators
- Other toolchains: asdf, mise, Flutter, Haskell, Elixir, PHP, .NET, Julia,
  Terraform, Bazel, Conan, Swift toolchains, Nix garbage
- Docker images, stopped containers, unused volumes, build cache; Docker
  Desktop, OrbStack, Colima, Lima, Podman, Rancher Desktop; Vagrant boxes and
  VMs from Parallels, VMware Fusion, VirtualBox, UTM, Tart and minikube
- Editors: VS Code/Cursor/VSCodium/Windsurf caches and logs, obsolete and
  duplicate extension versions, state for folders that no longer exist, and
  settings of old JetBrains and Android Studio versions
- AI models from Ollama, LM Studio, Hugging Face, GPT4All, Jan, Whisper,
  PyTorch, Keras, Draw Things, DiffusionBee and Chrome's on-device model

**Your files**
- Large files, duplicate files (byte-for-byte, one copy always kept), old
  downloads, installers and disk images (`.dmg`, `.pkg`, `.iso`, `.xip`,
  `.ipsw`, macOS installers)
- iPhone and iPad backups
- Mail, Messages, WhatsApp, Slack, Teams and Zoom attachments and caches
- `.DS_Store` files, AppleDouble `._` files, Windows leftovers and broken symlinks

## Build and run

You need macOS 13 or later and Xcode (or the Command Line Tools, `xcode-select --install`).

```bash
git clone https://github.com/gwilltsherman-byte/macsweep.git
cd MacSweep
./build.sh                  # or ./build.sh --universal for Apple silicon + Intel
open build/MacSweep.app
```

Every push also builds the app on GitHub Actions (the **Build** workflow),
runs the tests, and launches the app on a Mac runner to make sure it scans
without crashing. The zipped app is attached to each run as an artifact. It's signed ad hoc rather than with a developer certificate, so
the first time you open a downloaded copy, right-click it and choose
**Open**, or run `xattr -dr com.apple.quarantine MacSweep.app`.

## Permissions

- **Full Disk Access** lets MacSweep see the Trash, Mail, Messages, Safari,
  device backups and other apps' containers. Turn it on in System Settings ›
  Privacy & Security › Full Disk Access, then reopen MacSweep. Because the
  app is signed ad hoc, you'll need to turn it on again after rebuilding.
- macOS asks once for access to Desktop, Documents and Downloads, and for
  permission to control System Events (used to list login items) and Finder
  (only if you click **Empty Trash**).
- Items outside your home folder (for example in `/Library`) need your
  administrator password. MacSweep collects all of them into one prompt.
  Anything removed as administrator is deleted directly, not moved to the Trash.

## How it keeps you safe

- Nothing is pre-selected and nothing happens without the confirmation sheet,
  which lists every item, warns about running apps, Caution items and
  commands that can't be undone, and requires an extra tick for Caution items.
- A hard-coded list of locations can never be deleted whatever a scanner
  says: `/System`, `/usr` (except `/usr/local/…`), `/bin`, `/etc`, your home
  folder and its top-level folders, `~/Library/…` folders themselves,
  keychains, `~/.ssh` and others (see `Sources/SweepCore/Safety.swift`).
- Duplicate detection never lists the copy it keeps, and warns you if you
  tick every copy of a file some other way.
- If an uninstall command fails (say, Homebrew refuses because something
  depends on a package), that item's files are left alone.
- Package managers are used to remove their own packages (`brew uninstall`,
  `npm uninstall -g`, `cargo uninstall`, `pipx uninstall`, `xcrun simctl
  delete`, `docker image rm`, `ollama rm`…) so their records stay correct.

## Things it deliberately doesn't touch

- Unused language files inside apps. Removing them breaks the app's code
  signature, and macOS may then refuse to open it.
- System extensions, which only their own app (or System Settings) can remove.
- macOS itself, the sealed system volume, swap and the sleep image.
- Photos, Music and TV libraries. Edit those in their own apps.

## Project layout

```
Package.swift
build.sh                 builds and signs build/MacSweep.app
Resources/Info.plist
Sources/SweepCore/       scanning and removal engine (Foundation only)
  Scanners/              one function per category
  Catalog.swift          the list of categories
  Remover.swift          trash/delete, commands, one admin prompt
  Safety.swift           paths that are never deleted
Sources/MacSweep/        SwiftUI app
Tests/SweepCoreTests/    unit tests, including every scanner on a fake home folder
.github/workflows/       CI: tests, universal build, launch smoke test
```

`SweepCore` uses only Foundation, so its tests also run on Linux:

```bash
swift test                                   # on a Mac
docker run --rm -v "$PWD":/src -w /src swift:6.0 swift test   # anywhere else
```
