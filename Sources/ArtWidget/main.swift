import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = ArtStore()
    var panel: DesktopPanel?
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = DesktopPanel(store: store)
        panel.orderFrontRegardless()
        self.panel = panel

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        Task { await store.refreshIfNeeded() }
    }
}

/// `ArtWidget --snapshot out.png [--next | --back]` renders the card to a PNG and exits. For checking layout.
@MainActor
func snapshot(to path: String, next: Bool, back: Bool) async -> Bool {
    let store = ArtStore()
    if next {
        await store.next()
    } else if back {
        await store.back()
    } else {
        await store.refreshIfNeeded()
    }
    guard store.image != nil else { return false }
    let renderer = ImageRenderer(content: ArtCardView(store: store, rendersSnapshot: true))
    renderer.scale = 2
    guard let tiff = renderer.nsImage?.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}

let args = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
    let path = args[i + 1]
    let next = args.contains("--next")
    let back = args.contains("--back")
    Task { @MainActor in
        exit(await snapshot(to: path, next: next, back: back) ? 0 : 1)
    }
    app.run()
} else {
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.run()
}
