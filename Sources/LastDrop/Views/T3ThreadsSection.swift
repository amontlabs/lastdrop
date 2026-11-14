import SwiftUI

/// Settings → Claude → T3 Code threads, and a setup step: one switch that points T3 Code's Claude provider at
/// lastdrop's launcher (`T3Settings`), so its threads run on the account with room. The path to set by hand
/// stays behind a disclosure, for when the switch can't do it.
struct T3ThreadsSection: View {
    /// Setup shows it without the section title: the step already says what it is.
    var titled = true
    @State private var state = T3Settings.state()
    @State private var acp = T3Settings.acpStatus()
    @State private var error: String?
    @State private var askingToReplace: String?
    @State private var showingManual = false

    private var path: String { ThreadLauncher.wrapperPath.path }
    private let label = "Choose the Claude account for T3 Code threads"

    var body: some View {
        PageSection(titled ? "T3 Code threads" : nil) {
            Row(icon: "bubble.left.and.text.bubble.right", title: label,
                info: "Each new T3 Code thread starts on the Claude account with the most room, and moves only when that costs nothing. Sets T3 Code's Claude binary path to lastdrop's launcher. Turning it off puts the old value back.",
                detail: error ?? detail, detailColor: error == nil && !needsAttention ? .secondary : .orange) {
                RowSwitch(label: label, isOn: Binding(get: { state == .on }, set: { $0 ? turnOn() : turnOff() }))
                    .disabled(state == .notInstalled || state == .unreadable)
            }
            if let line = acpLine { Caption(line).padding(.top, 4) }
            DisclosureGroup("Set it by hand", isExpanded: $showingManual) {
                VStack(alignment: .leading, spacing: 6) {
                    Caption("1. Open T3 Code, then Settings → Providers → Claude.")
                    Caption("2. Paste this path into Binary path:")
                    HStack(spacing: 6) {
                        Text(path).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1)
                            .truncationMode(.middle).help(path).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(path, forType: .string)
                        }
                    }
                    Button("Open T3 Code") { NSWorkspace.shared.open(T3Settings.app) }
                        .disabled(!FileManager.default.fileExists(atPath: T3Settings.app.path))
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .padding(.top, 8)
        }
        .onAppear { refresh() }
        // Back from T3 Code, where the setting may have changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .alert("Replace T3 Code's Claude binary path?", isPresented: Binding(get: { askingToReplace != nil }, set: { if !$0 { askingToReplace = nil } })) {
            Button("Replace") { askingToReplace = nil; apply(replacing: true) }
            Button("Cancel", role: .cancel) { askingToReplace = nil }
        } message: {
            Text("It is set to \(askingToReplace ?? ""). Turning this off puts it back.")
        }
    }

    /// One quiet line about T3 Code's `lastdrop` provider, shown once the switch is on or the instance exists.
    private var acpLine: String? {
        switch acp {
        case .notInstalled, .unreadable: nil
        case .absent: state == .on ? "The lastdrop provider isn't in T3 Code yet. Turn this off and on again." : nil
        case .disabled: state == .on ? "The lastdrop provider is off in T3 Code." : nil
        case .ready: "The lastdrop provider is ready in T3 Code, for background tasks. A thread started on it has no T3 tools and loses its conversation on a rollback."
        case .wrapperMissing: "The lastdrop provider's launcher is missing. Turn this off and on again."
        case .foreign: "T3 Code has its own provider named lastdrop, so lastdrop left it alone."
        }
    }

    private var needsAttention: Bool {
        switch state {
        case .notInstalled, .unreadable, .elsewhere: true
        case .off, .on: false
        }
    }

    private var detail: String {
        switch state {
        case .notInstalled: "T3 Code not found"
        case .unreadable: "T3 Code's settings file can't be read. Set it by hand."
        case .off: "Off"
        case .on: "On. New threads use it now; running ones at their next start."
        case .elsewhere: "T3 Code's binary path points elsewhere. Turning this on asks first."
        }
    }

    private func refresh() { state = T3Settings.state(); acp = T3Settings.acpStatus() }

    private func turnOn() {
        error = nil
        if case .elsewhere(let other) = state { askingToReplace = other } else { apply(replacing: false) }
    }

    private func apply(replacing: Bool) {
        do { try T3Settings.enable(replacingElsewhere: replacing) } catch { self.error = "Couldn't change T3 Code's settings. Set it by hand." }
        refresh()
    }

    private func turnOff() {
        error = nil
        do { try T3Settings.disable() } catch { self.error = "Couldn't change T3 Code's settings. Set it by hand." }
        refresh()
    }
}
