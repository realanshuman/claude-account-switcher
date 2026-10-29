import AppKit
import SwiftUI

/// `ClaudeAccounts render-preview <folder>`: draws each state of the panel with sample
/// accounts, in light and dark, so the design can be checked without opening it.
@MainActor
enum Previews {
    static func render(to dir: URL) {
        _ = NSApplication.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let work = AccountRow(id: "a1", name: "work@example.com", detail: "Example Studio",
                              initials: "WE", tint: 0, isCurrent: true)
        let personal = AccountRow(id: "b2", name: "Personal", detail: "me@example.org · Last used 2 hours ago",
                                  initials: "PE", tint: 3, isCurrent: false)
        let rows = [personal, work]
        let switching = AccountsModel.Progress(target: "Personal", initials: "PE", tint: 3,
                                               leaving: "work@example.com", adding: false)
        var slow = switching
        slow.slowQuit = true
        var saving = switching
        saving.step = .signIn
        var done = switching
        done.step = .done

        let states: [(String, AccountsModel)] = [
            ("1-list", .preview(rows: rows)),
            ("2-hover", .preview(rows: rows, hover: "b2")),
            ("3-confirm", .preview(rows: rows, expanded: "b2")),
            ("4-add", .preview(rows: rows, expanded: AccountsModel.addRow, hover: AccountsModel.addRow)),
            ("5-quitting", .preview(rows: rows, progress: slow)),
            ("6-switching", .preview(rows: rows, progress: saving)),
            ("7-done", .preview(rows: rows, progress: done)),
            ("8-error", .preview(rows: rows, error: SwitchError.claudeDidNotQuit.localizedDescription)),
            ("9-signed-out", .preview(rows: [personal], signedIn: false)),
            ("10-remove", .preview(rows: rows, removing: "b2", hover: "b2")),
            ("11-closed", .preview(rows: rows, running: false)),
        ]
        for (name, model) in states {
            for dark in [false, true] {
                let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
                appearance.performAsCurrentDrawingAppearance {
                    let view = PanelCard(model: model)
                        .environment(\.isSnapshot, true)
                        .environment(\.colorScheme, dark ? .dark : .light)
                        .padding(24)
                        .background(dark ? Color(white: 0.16) : Color(white: 0.9))
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    guard let image = renderer.cgImage,
                          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
                    else { return }
                    try? png.write(to: dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
        }
        print("Rendered \(states.count * 2) previews to \(dir.path)")
    }
}
