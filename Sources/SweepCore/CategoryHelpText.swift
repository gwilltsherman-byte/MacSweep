import Foundation

/// Beginner-friendly explanations shown at the top of every category page.
/// Keep them short: what these things are, what happens if you delete them, and one practical tip.
enum CategoryHelpText {
    static let all: [String: CategoryHelp] = [
        // MARK: System junk
        "userCaches": CategoryHelp(
            "Copies that apps save so they can load things faster, like thumbnails, images and web pages they already downloaded. Each app has its own folder.",
            ifDeleted: "Nothing breaks. Apps quietly make new copies when they need them, so they may feel a little slower the first time you open them.",
            tip: "Quit an app before deleting its cache. Caches grow back over time, so the space you free may shrink again."),
        "systemCaches": CategoryHelp(
            "The same kind of speed-up copies, but shared by every user on this Mac and by parts of macOS itself.",
            ifDeleted: "macOS and apps rebuild them. Some can only be deleted with an administrator password.",
            tip: "Items rated Check first belong to macOS. Restart your Mac afterwards so it rebuilds them cleanly."),
        "appCaches": CategoryHelp(
            "Caches that some apps hide outside the usual Caches folder. Apps built on web technology (Slack, Discord, Teams, Chrome, VS Code and others) do this a lot.",
            ifDeleted: "The app downloads or rebuilds them again. Your messages, settings and sign-ins are not stored in these folders.",
            tip: "Quit the app first, or it may recreate the files straight away."),
        "xdgCache": CategoryHelp(
            "A hidden folder (.cache in your home folder) where command-line tools, mostly programming tools, keep their downloads.",
            ifDeleted: "The tools download the files again the next time they need them. If you never use Terminal, these are leftovers you won't miss."),
        "logs": CategoryHelp(
            "Diary-like text files in which apps and macOS write down what they did, plus reports saved whenever an app crashed.",
            ifDeleted: "Nothing about how your Mac or apps work changes. You only lose old history that helps when troubleshooting a problem."),
        "temp": CategoryHelp(
            "Scratch files that apps make while they work and are supposed to clean up afterwards, plus a few system caches such as the font cache.",
            ifDeleted: "Usually nothing noticeable. Anything changed in the last few days is rated Check first because an open app might still be using it.",
            tip: "Quit your apps first, and restart your Mac afterwards to be safe."),
        "savedState": CategoryHelp(
            "A note for each app of which windows it had open, so it can reopen them where you left off.",
            ifDeleted: "The app opens with a fresh, empty window next time. Your documents are not affected."),
        "trash": CategoryHelp(
            "Things you already moved to the Trash, on this Mac and on any connected drives.",
            ifDeleted: "They're deleted for good. It's the same as Empty Trash, but you can choose individual items."),
        "tmSnapshots": CategoryHelp(
            "Hourly backups that Time Machine keeps on your Mac's own disk while your backup drive isn't connected.",
            ifDeleted: "You can no longer restore files from those particular hours. Your real backups on the Time Machine drive are not touched.",
            tip: "macOS removes these by itself when space runs low, so you rarely need to."),

        // MARK: Apps & add-ons
        "apps": CategoryHelp(
            "Every app in your Applications folders, with when you last opened it.",
            ifDeleted: "The app is uninstalled along with its settings and support files. You can install it again later, but its settings will be gone.",
            tip: "Apps you haven't opened in months are good candidates. Apps from the App Store can be downloaded again for free."),
        "leftovers": CategoryHelp(
            "Settings and data folders left behind by apps you already deleted. Dragging an app to the Trash doesn't remove these.",
            ifDeleted: "Nothing you use should change. They're rated Check first because MacSweep matches them to apps by name and could be wrong.",
            tip: "If you don't recognise the name, look it up or leave it alone. Ones marked Still running come straight back until you stop what's running; click ⓘ to see how."),
        "launchItems": CategoryHelp(
            "Small helper programs and apps set to start automatically when you log in or turn on your Mac, such as updaters and menu-bar helpers.",
            ifDeleted: "They stop starting by themselves. The app they belong to stays installed, though it may add its helper back. Ones marked Broken point to programs that no longer exist.",
            tip: "Removing helpers you don't need can make your Mac start up faster."),
        "helpers": CategoryHelp(
            "Background tools that some apps install with administrator powers, for example to install their own updates.",
            ifDeleted: "Features of the app that need those powers may stop working until you reinstall it. Ones with no matching app are leftovers."),
        "plugins": CategoryHelp(
            "Add-ons that plug into macOS or other apps: sound plug-ins for music apps, printer and scanner drivers, preview plug-ins, screen savers and more.",
            ifDeleted: "Whatever the add-on provided goes away (for example, an old printer may stop working). Your other apps keep working.",
            tip: "Only remove add-ons for software or devices you no longer use."),
        "fonts": CategoryHelp(
            "Extra typefaces that you or your apps installed. Fonts that come with macOS are never listed here.",
            ifDeleted: "Documents that use a deleted font will show a different font instead."),
        "receipts": CategoryHelp(
            "Software that was installed with a .pkg installer, which can put files in many places. MacSweep uses the installer's own record of which files it added.",
            ifDeleted: "Those files are deleted permanently (an administrator password is needed), which uninstalls that software. Items marked Receipt only are just old records.",
            tip: "If the software has its own uninstaller, use that instead."),
        "appleExtras": CategoryHelp(
            "Optional extras from Apple: sound libraries for GarageBand and Logic Pro, leftovers from macOS upgrades, and extra dictionaries.",
            ifDeleted: "GarageBand and Logic offer to download the sounds again when you need them. Upgrade leftovers are old settings files you rarely need."),
        "games": CategoryHelp(
            "Games installed through Steam or the Epic Games launcher, and temporary files Steam keeps.",
            ifDeleted: "Steam asks you to confirm and then uninstalls the game. Your progress is usually saved in the cloud, and you can reinstall any time."),

        // MARK: Developer
        "brewFormulae": CategoryHelp(
            "Programs installed with Homebrew, a popular tool for installing software from Terminal.",
            ifDeleted: "Homebrew uninstalls them. Ones marked Unused dependency were only installed because another program needed them, and nothing needs them any more.",
            tip: "If you never use Terminal, these probably came with a developer setup you no longer use."),
        "brewCasks": CategoryHelp(
            "Ordinary Mac apps that were installed through Homebrew instead of being dragged into Applications.",
            ifDeleted: "Homebrew uninstalls the app. Its settings stay behind and will show up under App Leftovers after the next scan."),
        "brewMaintenance": CategoryHelp(
            "Old versions and installer downloads that Homebrew keeps around, plus extra software lists (called taps).",
            ifDeleted: "Homebrew keeps working as before. You just can't switch back to the older versions."),
        "macports": CategoryHelp(
            "Programs installed with MacPorts, an older Terminal-based way to install software.",
            ifDeleted: "MacPorts uninstalls them. An administrator password is needed."),
        "projects": CategoryHelp(
            "Folders that programming tools create inside code projects, such as node_modules (downloaded code libraries) and build folders.",
            ifDeleted: "The project's own files are untouched. These folders are made again the next time the project is built or set up.",
            tip: "Old projects you no longer work on are the best candidates."),
        "xcode": CategoryHelp(
            "Space used by Xcode, Apple's app for making apps: build files, iPhone and iPad simulators, and support files for devices you plugged in.",
            ifDeleted: "Xcode recreates build files and can download simulators again. Archives (saved copies of apps you published) are rated Careful."),
        "node": CategoryHelp(
            "Files for JavaScript programming: extra versions of Node.js, globally installed tools, and download caches.",
            ifDeleted: "Caches are downloaded again when needed. Deleting a Node.js version breaks projects that need exactly that version until it's reinstalled."),
        "python": CategoryHelp(
            "Extra versions of Python, project environments (a separate set of add-on packages for each project), and download caches.",
            ifDeleted: "Environments can be recreated from the project's list of packages. Deleting a Python version breaks programs that use it."),
        "ruby": CategoryHelp(
            "Extra versions of the Ruby programming language, Ruby add-on packages (gems), and CocoaPods data.",
            ifDeleted: "Packages are downloaded again when a project needs them. Deleting a Ruby version breaks programs that use it."),
        "rust": CategoryHelp(
            "Rust programming tools, downloaded code libraries, and programs installed with cargo.",
            ifDeleted: "Libraries are downloaded again on the next build. Deleting a toolchain or tool means reinstalling it if you need it again."),
        "go": CategoryHelp(
            "Downloads for the Go programming language (the module cache), tools installed with go install, and extra Go versions.",
            ifDeleted: "Downloads come back automatically on the next build. Tools and versions need reinstalling if you use them."),
        "jvm": CategoryHelp(
            "Files for Java, Kotlin and Android development: download caches, Java development kits, Android SDK parts and phone emulators.",
            ifDeleted: "Caches are downloaded again on the next build. Emulators lose the apps and data inside them."),
        "otherToolchains": CategoryHelp(
            "Files from many other programming tools: Flutter, Haskell, Elixir, PHP, .NET, Julia, Terraform, Bazel, Nix and more.",
            ifDeleted: "Caches are downloaded again when needed. Removing a version or tool means reinstalling it if you still use it."),
        "docker": CategoryHelp(
            "Docker images and containers (packaged software that developers run in isolation) and virtual machines (whole computers running inside your Mac).",
            ifDeleted: "Images can be downloaded again. Containers, volumes and virtual machines can hold data that's lost for good, so they're rated Careful.",
            tip: "Quit Docker and any virtual machine apps before deleting their files."),
        "ide": CategoryHelp(
            "Leftovers from code editors such as VS Code, Cursor and JetBrains apps: caches, old copies of extensions, and settings from older versions.",
            ifDeleted: "Editors rebuild their caches. Your current settings and installed extensions stay as they are."),
        "ai": CategoryHelp(
            "AI models you downloaded to run on your own Mac, for example with Ollama or LM Studio. Each one is often several gigabytes.",
            ifDeleted: "The app can download the model again, which takes time and internet data."),

        // MARK: Your files
        "largeFiles": CategoryHelp(
            "The biggest files in your home folder: videos, disk images, archives and the like.",
            ifDeleted: "They go to the Trash. Only you know if you still need them, so each one is rated Check first.",
            tip: "Copy anything you want to keep to an external drive or cloud storage before deleting it."),
        "duplicates": CategoryHelp(
            "Files that are exact copies of another file, byte for byte. MacSweep always keeps one copy and never lists it.",
            ifDeleted: "The extra copy goes to the Trash. The copy MacSweep keeps stays where it is.",
            tip: "Click an item to see which copy is kept. If you'd rather keep the other one, untick this item."),
        "oldDownloads": CategoryHelp(
            "Things in your Downloads folder that you haven't opened or changed in a long time.",
            ifDeleted: "They go to the Trash. Most downloads can be downloaded again if you need them."),
        "installers": CategoryHelp(
            "Installer files (.dmg and .pkg) and disk images you downloaded to install apps, plus big macOS installers and iPhone updates.",
            ifDeleted: "Apps you already installed keep working. You'd need to download the installer again to reinstall."),
        "backups": CategoryHelp(
            "Backups of iPhones and iPads that Finder (or iTunes) saved on this Mac.",
            ifDeleted: "The backup is gone for good. If the device also backs up to iCloud, or you no longer have it, you may not need it.",
            tip: "This may be the only copy of photos and messages from an old phone. Keep it if you're not sure."),
        "attachments": CategoryHelp(
            "Copies of files you received in Mail, Messages and chat apps such as WhatsApp, Slack, Teams and Zoom.",
            ifDeleted: "Mail's copies are safe to remove because the originals stay in your email. Messages and WhatsApp media may be the only copy."),
        "clutter": CategoryHelp(
            "Tiny invisible files that Finder and Windows create (like .DS_Store), and shortcuts that point to things that no longer exist.",
            ifDeleted: "Nothing important happens. Finder recreates its files, though folders may forget custom icon positions."),
    ]
}
