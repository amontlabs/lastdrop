import AppKit
import SwiftUI

/// lastdrop's one window: Settings, or on first launch, setup in its place. The panel only shows usage.
@MainActor
enum WindowPresenter {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    private static var placeObservers: [NSObjectProtocol] = []
    static let size = NSSize(width: 780, height: 600)

    static func settings(_ model: AppModel, page: SettingsPage? = nil) {
        if let page { model.settingsPage = page }
        model.settingUp = false
        show(model)
    }

    static func setup(_ model: AppModel) {
        model.settingUp = true
        show(model)
    }

    static func close() { window?.close() }

    private static func show(_ model: AppModel) {
        if let window {
            bringForward(window)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "lastdrop"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: MainWindowView(model: model))
        host.sizingOptions = []   // the window keeps its size; long pages scroll
        window.contentViewController = host
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: 680, height: 460)
        window.center()
        self.window = window
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windowClosed() }
        }
        // AppKit puts the buttons back on a resize and on leaving full screen.
        placeObservers = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { TrafficLights.place(window) }
            }
        }
        TrafficLights.place(window)
        bringForward(window)
    }

    /// A menu bar app can't take the front by itself (macOS keeps it behind the active app), so while its window is
    /// open it acts as a regular app, with a Dock icon, and it comes forward.
    private static func bringForward(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// Back to the menu bar alone once the window closes.
    private static func windowClosed() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        placeObservers.forEach(NotificationCenter.default.removeObserver)
        placeObservers = []
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Setup in the window's place on first launch, else Settings.
struct MainWindowView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.settingUp {
                SetupView(model: model)
            } else {
                SettingsView(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea(edges: .top)
        .tint(Brand.accent)
    }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case accounts, claude, agents, general
    var id: String { rawValue }

    /// The pages at the top of the sidebar; General sits at its bottom.
    static let main: [SettingsPage] = [.accounts, .claude, .agents]

    var title: String {
        switch self {
        case .accounts: "Accounts"
        case .claude: "Claude"
        case .agents: "Agents"
        case .general: "General"
        }
    }

    /// Beside the title: what the page is about.
    var about: String {
        switch self {
        case .accounts: "Your plans, what each shows in the menu bar, and when it notifies you."
        case .claude: "How lastdrop works with Claude Code: subagents and T3 Code threads on the Claude account with room, and saving usage."
        case .agents: "Extra models Claude Code can call, run on your other plans."
        case .general: "Opening lastdrop at login, and its new releases from GitHub."
        }
    }

    var icon: String {
        switch self {
        case .accounts: "person.2"
        case .claude: "sparkle"
        case .agents: "person.crop.rectangle.stack"
        case .general: "gearshape"
        }
    }

    /// The provider whose mark stands in for the icon.
    var logo: ProviderID? { self == .claude ? .claude : nil }
}

/// Settings: an inset sidebar on glass, and the page beside it.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var adding = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Design.sidebarWidth)
                .frame(maxHeight: .infinity)
                .glassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(Design.sidebarInset)
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
    }

    @ViewBuilder private var page: some View {
        switch model.settingsPage {
        case .accounts:
            Page(title: "Accounts", info: SettingsPage.accounts.about) {
                Button("Add account…") { model.connectStatus = .idle; adding = true }
            } content: {
                AccountsSections(model: model)
            }
        case .claude:
            Page(title: "Claude", info: SettingsPage.claude.about) {
                AgentsSwitchSection(model: model)
                T3ThreadsSection()
                if model.agentsEnabled {
                    SaveClaudeSection()
                    AccountLimitsSection(model: model)
                }
            }
        case .agents:
            Page(title: "Agents", info: SettingsPage.agents.about) {
                if model.agentsEnabled { AgentsSections(model: model) } else { AgentsOffSection(model: model) }
            }
        case .general:
            Page(title: "General", info: SettingsPage.general.about) {
                PageSection { LoginRow(model: model) }
                UpdatesSection(model: model)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.main) { sidebarButton($0) }
            Spacer()
            if model.needsRepair {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Plugin problem").font(.callout.weight(.medium))
                        InfoTip(model.claudeError ?? "")
                    }
                    Button("Repair") { model.repair() }.controlSize(.small)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            sidebarButton(.general)
        }
        .padding(.horizontal, 8)
        // Below the window's buttons, which sit on the sidebar.
        .padding(.top, Design.titleBar - Design.sidebarInset)
        .padding(.bottom, 10)
    }

    private func sidebarButton(_ page: SettingsPage) -> some View {
        Button { model.settingsPage = page } label: {
            HStack(spacing: 8) {
                Group {
                    if let logo = page.logo {
                        Image(nsImage: Logos.image(logo)).renderingMode(.template).resizable().scaledToFit().frame(width: 13, height: 13)
                    } else {
                        Image(systemName: page.icon).font(.system(size: 13))
                    }
                }
                .foregroundStyle(page == model.settingsPage ? Color.accentColor : .secondary)
                .frame(width: 18)
                Text(page.title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(page == model.settingsPage ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
