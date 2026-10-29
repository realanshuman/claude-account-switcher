import AppKit
import SwiftUI

/// `ClaudeAccounts probe-panel`: builds the real panel off screen and prints the card
/// frames it reports, to check the click-through area without opening it on screen.
@MainActor
enum PanelProbe {
    static func run() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let row = AccountRow(id: "a1", name: "work@example.com", detail: "Example Studio", initials: "WE", tint: 0, isCurrent: true)
        let model = AccountsModel.preview(rows: [row])
        let size = NSSize(width: PanelMetrics.width + PanelMetrics.margin * 2, height: 640)
        let panel = FloatingPanel(content: PanelRoot(model: model) { frame in
            print("card frame reported:", NSStringFromRect(frame))
        }, size: size)
        panel.setFrame(NSRect(x: -30000, y: -30000, width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        print("expanding a row")
        withAnimation { model.expanded = AccountsModel.addRow }
        try? await Task.sleep(nanoseconds: 600_000_000)
        panel.orderOut(nil)
    }
}
