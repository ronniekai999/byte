import AppKit
import SwiftUI

@main
struct ByteApp: App {
    // The adaptor constructs the (main-actor) delegate on the main actor for us,
    // which avoids the actor-isolation error you get from top-level `AppDelegate()`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No visible primary window — the delegate builds the notch window itself.
        Settings { EmptyView() }
    }
}

/// Borderless windows can't become key by default, which breaks SwiftUI text
/// input, gestures and context menus. Allow it.
final class NotchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NotchWindow!
    let model = ByteModel()

    private var expanded = false
    private let compact = NSSize(width: 220, height: 170)
    private let opened  = NSSize(width: 360, height: 560)

    // Pinned position (top-center anchor in global screen coords), persisted.
    private var dragStartOrigin = CGPoint.zero
    private let pinnedKey  = "byte.pinned"
    private let pinXKey    = "byte.pinX"
    private let pinTopYKey = "byte.pinTopY"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon

        let hosting = NSHostingView(rootView: ByteView(model: model))

        let window = NotchWindow(
            contentRect: NSRect(origin: .zero, size: compact),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]
        self.window = window

        position()
        window.orderFrontRegardless()

        // Grow/shrink the window when the chat panel opens or closes.
        model.onChatOpenChanged = { [weak self] open in self?.setExpanded(open) }

        // Drag-to-move / pin-anywhere.
        model.onDragBegan     = { [weak self] in self?.dragBegan() }
        model.onDragChanged   = { [weak self] t in self?.dragChanged(t) }
        model.onDragEnded     = { [weak self] in self?.dragEnded() }
        model.onResetPosition = { [weak self] in self?.resetPosition() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false   // accessory app keeps running with no standard windows
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.prepareForTermination()
    }

    @objc private func screensChanged() { position() }

    private func setExpanded(_ open: Bool) {
        guard expanded != open else { return }
        expanded = open
        position(animated: true)
    }

    /// Place the window so its top-center sits at the pinned anchor — or, if Byte
    /// hasn't been moved, at the top-center of the notched display. The window is
    /// kept fully on whichever display the anchor lands on.
    private func position(animated: Bool = false) {
        let size = expanded ? opened : compact
        var (ax, aTop) = anchorPoint()

        // If the pinned point is on no current display (e.g. a monitor was
        // unplugged), fall back to the notch.
        var host = screen(containing: CGPoint(x: ax, y: aTop - 1))
        if host == nil, let s = notchedScreen() {
            host = s; ax = s.frame.midX; aTop = s.frame.maxY
        }
        guard let disp = host ?? NSScreen.main else { return }

        var x = ax - size.width / 2
        var y = aTop - size.height                       // origin is bottom-left
        let f = disp.frame
        x = min(max(x, f.minX), f.maxX - size.width)
        y = min(max(y, f.minY), f.maxY - size.height)
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                        display: true, animate: animated)
    }

    /// Top-center anchor: the user's pinned point if set, else the notch.
    private func anchorPoint() -> (CGFloat, CGFloat) {
        let d = UserDefaults.standard
        if d.bool(forKey: pinnedKey),
           d.object(forKey: pinXKey) != nil, d.object(forKey: pinTopYKey) != nil {
            return (CGFloat(d.double(forKey: pinXKey)), CGFloat(d.double(forKey: pinTopYKey)))
        }
        let s = notchedScreen() ?? NSScreen.main
        return (s?.frame.midX ?? 0, s?.frame.maxY ?? 0)
    }

    private func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSPointInRect(p, $0.frame) }
    }

    // MARK: - Drag to move / pin

    private func dragBegan() { dragStartOrigin = window.frame.origin }

    private func dragChanged(_ t: CGSize) {
        // SwiftUI translation grows down/right; window origin grows up/right.
        var o = CGPoint(x: dragStartOrigin.x + t.width,
                        y: dragStartOrigin.y - t.height)
        let s = window.frame.size
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        if !union.isNull {
            o.x = min(max(o.x, union.minX), union.maxX - s.width)
            o.y = min(max(o.y, union.minY), union.maxY - s.height)
        }
        window.setFrameOrigin(o)
    }

    private func dragEnded() {
        let f = window.frame
        let d = UserDefaults.standard
        d.set(true, forKey: pinnedKey)
        d.set(Double(f.midX), forKey: pinXKey)
        d.set(Double(f.maxY), forKey: pinTopYKey)
    }

    /// Forget the pinned spot and snap back under the notch.
    func resetPosition() {
        let d = UserDefaults.standard
        d.set(false, forKey: pinnedKey)
        d.removeObject(forKey: pinXKey)
        d.removeObject(forKey: pinTopYKey)
        position(animated: true)
    }

    private func notchedScreen() -> NSScreen? {
        if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) { return s }
        return NSScreen.main
    }
}
