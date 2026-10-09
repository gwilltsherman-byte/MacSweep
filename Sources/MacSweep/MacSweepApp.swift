import AppKit
import SwiftUI

@main
enum Entry {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        // Used by build.sh to produce the app icon.
        if let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count {
            _ = NSApplication.shared
            exit(IconArt.writePNG(to: arguments[index + 1], size: 1024) ? 0 : 1)
        }
        MacSweepApp.main()
    }
}

struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacSweep") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
        }
        .defaultSize(width: 1200, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Scan Everything") { model.scanAll() }
                    .keyboardShortcut("r")
                    .disabled(model.isScanning)
                Button("Stop Scanning") { model.cancelScan() }
                    .keyboardShortcut(".")
                    .disabled(!model.isScanning)
                Divider()
                Button("Select Everything Marked Safe") { model.checkAllSafe() }
                    .disabled(model.isScanning)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil {
            NSApp.applicationIconImage = IconArt.image(size: 512)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum IconArt {
    static func image(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            draw(in: rect)
            return true
        }
    }

    static func draw(in rect: NSRect) {
        let side = rect.width
        let tile = rect.insetBy(dx: side * 0.1, dy: side * 0.1)
        let shape = NSBezierPath(roundedRect: tile, xRadius: side * 0.18, yRadius: side * 0.18)
        let gradient = NSGradient(colors: [
            NSColor(calibratedRed: 0.16, green: 0.56, blue: 1.0, alpha: 1),
            NSColor(calibratedRed: 0.45, green: 0.27, blue: 0.96, alpha: 1),
        ])
        gradient?.draw(in: shape, angle: -65)

        guard let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil),
              let configured = symbol.withSymbolConfiguration(.init(pointSize: side * 0.4, weight: .semibold)) else { return }
        let tinted = NSImage(size: configured.size, flipped: false) { bounds in
            configured.draw(in: bounds)
            NSColor.white.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let origin = NSPoint(x: rect.midX - tinted.size.width / 2, y: rect.midY - tinted.size.height / 2)
        tinted.draw(in: NSRect(origin: origin, size: tinted.size))
    }

    static func writePNG(to path: String, size: Int) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data)
    }
}
