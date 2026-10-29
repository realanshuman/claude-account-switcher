import AppKit
import SwiftUI

/// Snapshots draw with ImageRenderer, which can't draw AppKit-backed views: they get
/// a flat background and a plain image for each menu.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// The panel window's content: the card at the top, with room around it for its shadow.
struct PanelRoot: View {
    @ObservedObject var model: AccountsModel
    var onCardFrame: (CGRect) -> Void

    var body: some View {
        PanelCard(model: model)
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }, action: onCardFrame)
            .padding(.horizontal, PanelMetrics.margin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

enum PanelMetrics {
    static let width: CGFloat = 320
    static let margin: CGFloat = 24
}

struct PanelCard: View {
    @ObservedObject var model: AccountsModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        VStack(spacing: 0) {
            Header(model: model)
            Divider().opacity(0.6)
            ZStack(alignment: .top) {
                if let progress = model.progress {
                    ProgressCard(progress: progress, canCancel: model.canCancel, cancel: model.cancelSwitch)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    AccountList(model: model)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
        }
        .frame(width: PanelMetrics.width)
        .background(isSnapshot ? AnyView(Color(nsColor: .windowBackgroundColor)) : AnyView(Material()))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

private struct Material: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: Header

private struct Header: View {
    @ObservedObject var model: AccountsModel
    @Environment(\.isSnapshot) private var isSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude accounts")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(model.claudeRunning ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 8)
            if model.claudeInstalled, !model.claudeRunning, model.progress == nil {
                Button("Open Claude", action: model.openClaude)
                    .buttonStyle(OutlineButtonStyle())
                    .transition(.opacity)
            }
            if isSnapshot {
                MoreIcon()
            } else {
                Menu {
                    Toggle("Open at Login", isOn: Binding(get: { model.openAtLogin },
                                                          set: { model.setOpenAtLogin($0) }))
                    Button("Show Saved Sign-ins in Finder", action: model.showSavedSignIns)
                    Divider()
                    Button("Quit Claude Accounts") { NSApp.terminate(nil) }
                } label: {
                    MoreIcon()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var status: String {
        guard model.claudeInstalled else { return "Claude isn't installed" }
        if !model.claudeRunning { return "Claude is closed" }
        return model.signedIn ? "Claude is open" : "Claude is open, signed out"
    }
}

private struct MoreIcon: View {
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 22)
            .contentShape(Rectangle())
    }
}

// MARK: Accounts

private struct AccountList: View {
    @ObservedObject var model: AccountsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let error = model.error {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error,
                       dismiss: model.dismissError)
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !model.claudeInstalled {
                Notice(symbol: "app.badge", tint: .secondary,
                       text: "Install the Claude app to switch between accounts.")
            } else if !model.signedIn {
                Notice(symbol: "person.crop.circle", tint: .secondary, text: model.rows.isEmpty
                    ? "Claude is signed out. Sign in there and your account shows up here."
                    : "Claude is signed out. Sign in there to add an account, or switch to a saved one.")
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
            ForEach(model.rows) { row in
                AccountRowView(model: model, row: row)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if model.claudeInstalled, model.signedIn {
                AddRow(model: model)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AccountRowView: View {
    @ObservedObject var model: AccountsModel
    let row: AccountRow
    @State private var hovering = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool
    @Environment(\.isSnapshot) private var isSnapshot

    private var expanded: Bool { model.expanded == row.id }
    private var removing: Bool { model.removing == row.id }
    private var renaming: Bool { model.renaming == row.id }
    private var hovered: Bool { hovering || model.previewHover == row.id }
    private var highlighted: Bool { (hovered && !row.isCurrent) || expanded || removing }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Avatar(initials: row.initials, tint: row.tint)
                VStack(alignment: .leading, spacing: 1) {
                    if renaming {
                        TextField("Name", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .focused($nameFocused)
                            .onSubmit { model.commitRename(row.id, to: draft) }
                            .onExitCommand { model.cancelRename() }
                            .onAppear {
                                draft = row.name
                                nameFocused = true
                            }
                    } else {
                        Text(row.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text(renaming ? "Press Return to save, Esc to cancel" : row.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                trailing
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { if !renaming { model.tap(row.id) } }

            if expanded {
                Confirm(text: "Claude restarts to switch. Anything running in it stops, and \(model.currentName ?? "the current account") stays signed in here.",
                        action: "Switch", cancel: { model.tap(row.id) }, confirm: { model.switchTo(row.id) })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if removing {
                Confirm(text: "Delete the saved sign-in for \(row.name) from this Mac? To use it again, add it and sign in.",
                        action: "Remove", destructive: true,
                        cancel: model.cancelRemove, confirm: { model.confirmRemove(row.id) })
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(highlighted ? 0.06 : 0)))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .contextMenu {
            Button("Rename…") { model.beginRename(row.id) }
            if !row.isCurrent {
                Button("Remove…") { model.beginRemove(row.id) }
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if row.isCurrent {
            Text("In use")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
        } else if hovered, !expanded, !removing, !renaming {
            Text("Switch")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .transition(.opacity)
        }
        if hovered, !renaming {
            if isSnapshot {
                MoreIcon()
            } else {
                Menu {
                    Button("Rename…") { model.beginRename(row.id) }
                    if !row.isCurrent {
                        Button("Remove…") { model.beginRemove(row.id) }
                    }
                } label: {
                    MoreIcon()
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .transition(.opacity)
            }
        }
    }
}

private struct AddRow: View {
    @ObservedObject var model: AccountsModel
    @State private var hovering = false

    private var expanded: Bool { model.expanded == AccountsModel.addRow }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                Text("Add another account")
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .onTapGesture { model.tap(AccountsModel.addRow) }

            if expanded {
                Confirm(text: "Claude restarts at the sign-in screen. Sign in there with the other account. \(model.currentName ?? "This account") stays signed in here.",
                        action: "Continue", cancel: { model.tap(AccountsModel.addRow) }, confirm: model.addAccount)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovering || expanded || model.previewHover == AccountsModel.addRow ? 0.06 : 0)))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
    }
}

private struct Confirm: View {
    let text: String
    let action: String
    var destructive = false
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: cancel)
                    .buttonStyle(OutlineButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(action, action: confirm)
                    .buttonStyle(FilledButtonStyle(destructive: destructive))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.leading, 46)
        .padding(.trailing, 8)
        .padding(.bottom, 10)
    }
}

private struct Avatar: View {
    let initials: String
    let tint: Int

    var body: some View {
        let color = AccountsModel.palette[tint % AccountsModel.palette.count]
        Text(initials)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 28, height: 28)
            .background(Circle().fill(color.opacity(0.16)))
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

// MARK: Progress

private struct ProgressCard: View {
    let progress: AccountsModel.Progress
    let canCancel: Bool
    let cancel: () -> Void

    private var done: Bool { progress.step == .done }

    private var steps: [(SwitchStep, String)] {
        [(.quit, "Quit Claude"),
         (.save, progress.leaving.map { "Save \($0)" } ?? "Back up the current sign-in"),
         (.signIn, progress.adding ? "Clear the sign-in" : "Sign in as \(progress.target)"),
         (.open, progress.adding ? "Open Claude at the sign-in screen" : "Open Claude")]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if progress.adding {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                } else {
                    Avatar(initials: progress.initials, tint: progress.tint)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .contentTransition(.opacity)
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(steps, id: \.0) { step, label in
                    StepRow(label: label, state: state(of: step),
                            note: step == .quit && progress.slowQuit && progress.step == .quit
                                ? "Claude may be asking you to confirm. Choose Quit there." : nil)
                }
            }
            if canCancel {
                HStack {
                    Spacer()
                    Button("Cancel", action: cancel)
                        .buttonStyle(OutlineButtonStyle())
                        .keyboardShortcut(.cancelAction)
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        if progress.adding { return done ? "Ready for the other account" : "Adding an account" }
        return done ? "Signed in as \(progress.target)" : "Switching to \(progress.target)"
    }

    private var subtitle: String {
        if done { return progress.adding ? "Sign in to Claude with it." : "Claude is opening." }
        return "Claude restarts to switch."
    }

    private func state(of step: SwitchStep) -> StepRow.State {
        if step < progress.step || done { return .done }
        return step == progress.step ? .active : .pending
    }
}

private struct StepRow: View {
    enum State { case pending, active, done }

    let label: String
    let state: State
    var note: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                switch state {
                case .pending:
                    Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1.2)
                        .frame(width: 13, height: 13)
                case .active:
                    Spinner()
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12, weight: state == .active ? .medium : .regular))
                    .foregroundStyle(state == .pending ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
        }
    }
}

private struct Spinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

// MARK: Buttons

struct FilledButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(destructive ? Color.red : Color.accentColor))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}
