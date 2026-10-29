import AppKit
import Combine
import SwiftUI

/// A borderless panel that can take keyboard focus (for renaming) without making
/// this app the active one.
final class FloatingPanel: NSPanel {
    var onEscape: () -> Void = {}

    init<Content: View>(content: Content, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape()
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private static let panelSize = NSSize(width: PanelMetrics.width + PanelMetrics.margin * 2, height: 640)

    private let model = AccountsModel(store: AccountStore())
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    /// The card's frame in the panel's own coordinates. Everywhere else in the panel is
    /// transparent, and lets clicks through to whatever is behind it.
    private var cardFrame: NSRect = .zero
    private var monitors: [Any] = []
    private var refreshTimer: Timer?
    private var visible = false
    private var hiddenAt = Date.distantPast
    private var watchers: [AnyCancellable] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        setIcon(busy: false)

        panel = FloatingPanel(content: PanelRoot(model: model) { [weak self] frame in
            self?.cardMoved(frame)
        }, size: Self.panelSize)
        panel.onEscape = { [weak self] in
            guard let self, !self.model.escape() else { return }
            self.hide()
        }
        model.onFinished = { [weak self] in self?.hide() }
        model.onNeedsAttention = { [weak self] in self?.show() }

        model.$progress.map { $0 != nil }.removeDuplicates()
            .sink { [weak self] busy in self?.setIcon(busy: busy) }
            .store(in: &watchers)
        model.$rows
            .sink { [weak self] rows in
                let name = rows.first(where: \.isCurrent)?.name
                self?.statusItem.button?.toolTip = name.map { "Claude accounts: \($0)" } ?? "Claude accounts"
            }
            .store(in: &watchers)

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == ClaudeApp.bundleID {
                    MainActor.assumeIsolated { self?.model.refresh() }
                }
            }
        }
        model.refresh()

        // The icon can end up hidden behind the notch, so the first launch shows the panel
        // once, and opening the app again (Finder, Spotlight, Raycast) always does.
        if !UserDefaults.standard.bool(forKey: "shownOnce") {
            UserDefaults.standard.set(true, forKey: "shownOnce")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.show() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return false
    }

    private func setIcon(busy: Bool) {
        let image = NSImage(systemSymbolName: busy ? "arrow.triangle.2.circlepath" : "person.2.circle",
                            accessibilityDescription: "Claude accounts")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: Showing

    @objc private func toggle() {
        // A click on the icon also reaches the outside-click monitor, which may already
        // have closed the panel. That click was meant to close it, so it stays closed.
        if visible {
            hide()
        } else if Date().timeIntervalSince(hiddenAt) > 0.3 {
            show()
        }
    }

    private func show() {
        model.refresh()
        model.refreshLoginItem()
        let target = placement()
        if visible {
            panel.setFrame(target, display: true)
            panel.makeKey()
            return
        }
        visible = true
        panel.alphaValue = 0
        panel.setFrame(target.offsetBy(dx: 0, dy: 8), display: false)
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
        startWatching()
    }

    private func hide() {
        guard visible else { return }
        visible = false
        hiddenAt = Date()
        stopWatching()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
                self.model.reset()
            }
        })
    }

    /// Under the menu bar icon, or centered at the top of the screen when the icon is
    /// hidden behind the notch or can't be found.
    private func placement() -> NSRect {
        let size = Self.panelSize
        var screen = NSScreen.main ?? NSScreen.screens.first
        var anchor: NSPoint?
        if let icon = iconFrame(),
           let iconScreen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) }),
           !behindNotch(icon, on: iconScreen) {
            screen = iconScreen
            anchor = NSPoint(x: icon.midX, y: icon.minY - 6)
        }
        guard let screen else { return NSRect(origin: .zero, size: size) }
        let visibleFrame = screen.visibleFrame
        let top = anchor?.y ?? visibleFrame.maxY - 8
        let center = anchor?.x ?? screen.frame.midX
        let cardX = min(max(center - PanelMetrics.width / 2, visibleFrame.minX + 8),
                        visibleFrame.maxX - 8 - PanelMetrics.width)
        return NSRect(x: cardX - PanelMetrics.margin, y: top - size.height, width: size.width, height: size.height)
    }

    private func iconFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.width > 0 ? frame : nil
    }

    private func behindNotch(_ icon: NSRect, on screen: NSScreen) -> Bool {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else { return false }
        return icon.midX > left.maxX && icon.midX < right.minX
    }

    // MARK: Mouse and keyboard

    private func cardMoved(_ frame: CGRect) {
        let height = panel.contentView?.bounds.height ?? Self.panelSize.height
        cardFrame = NSRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        updateClickThrough()
    }

    private var cardOnScreen: NSRect {
        panel.convertToScreen(cardFrame)
    }

    /// The panel only takes the mouse over the card itself.
    private func updateClickThrough() {
        let over = cardOnScreen.insetBy(dx: -1, dy: -1).contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    private func startWatching() {
        updateClickThrough()
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateClickThrough()
            return event
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateClickThrough()
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if self.cardOnScreen.contains(point) { return }
            if let icon = self.iconFrame(), icon.contains(point) { return }
            self.hide()
        } as Any)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}
