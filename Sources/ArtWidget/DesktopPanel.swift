import AppKit
import SwiftUI

/// Borderless panel that sits on the desktop: above the wallpaper and icons, below every app window.
final class DesktopPanel: NSPanel, NSWindowDelegate {
    private static let positionKey = "topLeft"

    init(store: ArtStore) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 372, height: 240),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false   // the card draws its own
        isMovableByWindowBackground = true
        hidesOnDeactivate = false

        let actions = CardActions(
            resetPosition: { [weak self] in self?.resetPosition() },
            quit: { NSApp.terminate(nil) }
        )
        let root = ArtCardView(store: store, actions: actions) { [weak self] size in
            DispatchQueue.main.async { self?.fit(size) }
        }
        contentView = FirstMouseHostingView(rootView: root)
        move(to: savedTopLeft() ?? defaultTopLeft())
        delegate = self
    }

    private var topLeft: NSPoint { NSPoint(x: frame.minX, y: frame.maxY) }

    private func move(to point: NSPoint) {
        setFrame(NSRect(x: point.x, y: point.y - frame.height, width: frame.width, height: frame.height), display: true)
    }

    /// Resize to the card, growing downward so the top-left corner stays put.
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != frame.size else { return }
        let tl = topLeft
        setFrame(NSRect(x: tl.x, y: tl.y - size.height, width: size.width, height: size.height), display: true)
    }

    private func defaultTopLeft() -> NSPoint {
        let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let inset = ArtCardView.inset
        return NSPoint(x: visible.minX + 20 - inset, y: visible.maxY - 20 + inset)
    }

    private func savedTopLeft() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: Self.positionKey) else { return nil }
        let p = NSPointFromString(s)
        // Ignore positions on a display that's no longer connected.
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(p) } ? p : nil
    }

    private func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionKey)
        move(to: defaultTopLeft())
    }

    func windowDidMove(_ notification: Notification) {
        UserDefaults.standard.set(NSStringFromPoint(topLeft), forKey: Self.positionKey)
    }
}

/// Lets the first click land on the card without needing to focus it first.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
