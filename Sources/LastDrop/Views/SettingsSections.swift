import SwiftUI

// The sections Settings and first-launch setup share, so each setting looks and works the same in both. Each returns one
// or more `PageSection`s for a page's column.

/// Opening lastdrop when the Mac starts, as a row.
struct LoginRow: View {
    @Bindable var model: AppModel

    var body: some View {
        Row(icon: "power", title: "Open at login", detail: model.launchAtLoginError, detailColor: .orange) {
            RowSwitch(label: "Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .disabled(!AppModel.isBundled)
        }
    }
}

/// The connected accounts, by provider, then (in setup) the plans not connected yet.
struct AccountsSections: View {
    @Bindable var model: AppModel
    /// Also lists the providers not connected yet, each with its own button.
    var listsOthers = false
    @State private var connecting: ProviderID?
    @State private var renaming: AccountInfo?
    @State private var newName = ""
    @State private var catalog = AgentCatalog.load()

    var body: some View {
        let others = ProviderID.allCases.filter { !model.connectedProviders.contains($0) }
        Group {
            PageSection {
                if model.connectedProviders.isEmpty {
                    Caption("No accounts yet.").padding(.vertical, Design.rowPad)
                } else {
                    Nest {
                        ForEach(model.connectedProviders) { provider in
                            let accounts = model.accounts(provider)
                            NestLabel(text: provider.displayName, info: accounts.count > 1 && model.showsAgents ? footer(provider) : nil)
                            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, info in
                                row(info, index: index, count: accounts.count)
                            }
                            // Agents run on the provider's accounts, so the judge that checks their commands sits with them.
                            if model.agentsEnabled, let judged = AgentProvider.judged.first(where: { $0.usageID == provider }) {
                                RowDivider()
                                JudgeRow(provider: judged, chosen: catalog.judges[judged]) { judge in
                                    do { try AgentCatalog.update { $0.judges[judged] = judge }; catalog = AgentCatalog.load() } catch {}
                                }
                            }
                        }
                    }
                }
            }
            if listsOthers && !others.isEmpty {
                PageSection("Not connected") {
                    ForEach(Array(others.enumerated()), id: \.element) { index, provider in
                        if index > 0 { RowDivider() }
                        Row(title: provider.displayName, detail: provider.planHint) {
                            ProviderTile(id: provider)
                        } control: {
                            Button(provider.signsInWithBrowser ? "Sign in…" : "Add key…") { model.connectStatus = .idle; connecting = provider }
                        }
                    }
                }
            }
        }
        .keepingCatalog($catalog)
        .sheet(item: $connecting) { provider in AddAccountSheet(model: model, provider: provider) }
        .alert("Rename account", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let renaming { model.rename(renaming.id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func footer(_ provider: ProviderID) -> String {
        switch provider {
        case .claude: "Subagents go to the account with the most left. Ties follow this order."
        case .antigravity: "Agents use the first account: the Antigravity CLI signs in only one."
        default: "Agents go to the account with the most left. Ties follow this order."
        }
    }

    private func row(_ info: AccountInfo, index: Int, count: Int) -> some View {
        HStack(spacing: 10) {
            ProviderTile(id: info.account.provider)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(info.name).fontWeight(.medium)
                    if let plan = info.plan, plan != info.name { PlanChip(text: plan) }
                }
                if let problem = info.limits.problem {
                    // A rate limit clears by itself: grey, not orange. One line; the rest on hover.
                    Text(info.state.rateLimited ? "Busy, retrying soon" : problem)
                        .font(.callout)
                        .foregroundStyle(info.state.rateLimited ? .secondary : Color.orange)
                        .lineLimit(1)
                        .help(problem)
                } else if let email = info.email {
                    Text(email).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            // The icon goes inside each choice, so the dropdown shows it right beside the value.
            Picker("Menu bar", selection: Binding(get: { info.account.menuBar }, set: { model.setMenuBar(info.id, $0) })) {
                Label("Hidden", systemImage: "menubar.rectangle").tag(MenuBarMode?.none)
                Divider()
                if info.account.provider == .openrouter {
                    Label("Credits", systemImage: "menubar.rectangle").tag(MenuBarMode?.some(.session))
                } else {
                    ForEach(MenuBarMode.allCases) { Label($0.title, systemImage: "menubar.rectangle").tag(MenuBarMode?.some($0)) }
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Shown in the menu bar")
            Picker("Notify", selection: Binding(get: { info.account.notifyAt }, set: { model.setNotify(info.id, $0) })) {
                Label("Off", systemImage: "bell.slash").tag(Double?.none)
                Divider()
                ForEach(Account.notifyChoices, id: \.self) { Label(Account.notifyTitle($0), systemImage: "bell").tag(Double?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Notify when this much is left")
            Menu {
                Button("Rename…") { newName = info.name; renaming = info }
                if count > 1 {
                    Button("Move up") { model.moveAccount(info.id, by: -1) }.disabled(index == 0)
                    Button("Move down") { model.moveAccount(info.id, by: 1) }.disabled(index == count - 1)
                }
                if info.account.provider == .claude {
                    Button("Sign in again") { model.signInAgain(info.account.key) }
                    Button("Sign in again in Terminal") { model.signInInTerminal(info.account) }
                }
                if model.canRemove(info.account) {
                    Divider()
                    Button(info.account.isMain ? "Sign out" : "Remove", role: .destructive) { model.remove(info.account) }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 6)
    }
}

/// The switch for agents in Claude Code, and whether lastdrop's plugin is there.
struct AgentsSwitchSection: View {
    @Bindable var model: AppModel
    @State private var version: String?

    var body: some View {
        PageSection {
            Row(icon: "sparkle", color: ProviderID.claude.brandColors[0], title: "Agents in Claude Code",
                info: "Subagents run on whichever Claude account has the most left, and your other plans become agents Claude can call. Adds lastdrop's plugin to Claude Code.",
                detail: model.claudeError ?? status, detailColor: model.claudeError == nil && version != "" ? .secondary : .orange) {
                RowSwitch(label: "Agents in Claude Code", isOn: Binding(get: { model.agentsEnabled }, set: { model.setAgents($0) }))
                    .disabled(version == "")
            }
        }
        .task { version = await Task.detached { SubagentRunner.executable().map(SelfTest.version) ?? "" }.value }
    }

    private var status: String {
        guard let version else { return "Looking for Claude Code…" }
        if version.isEmpty { return "Claude Code not found" }
        let claude = version.replacingOccurrences(of: " (Claude Code)", with: "")
        return model.subagentsInstalled ? "Plugin installed · Claude Code \(claude)" : "Claude Code \(claude)"
    }
}

/// The Agents page while the switch is off: why it is empty, and the way to the switch.
struct AgentsOffSection: View {
    @Bindable var model: AppModel

    var body: some View {
        PageSection {
            Row(icon: "sparkle", color: ProviderID.claude.brandColors[0], title: "Agents need Agents in Claude Code",
                detail: "Turn it on to use your other plans as agents.") {
                Button("Open Claude") { model.settingsPage = .claude }
            }
        }
    }
}

/// Save Claude usage and its prompt.
struct SaveClaudeSection: View {
    @State private var catalog = AgentCatalog.load()
    @State private var editingPrompt = false
    @State private var error: String?

    var body: some View {
        PageSection {
            Row(icon: "leaf.fill", color: .green, title: "Save Claude usage",
                info: catalog.enabled.isEmpty ? "Add an agent first." : SaveClaudeToggle.about,
                detail: error, detailColor: .red) {
                RowSwitch(label: "Save Claude usage", isOn: Binding(get: { catalog.saveClaude }, set: { on in
                    do { try AgentCatalog.update { $0.saveClaude = on }; catalog = AgentCatalog.load(); error = nil } catch {
                        self.error = "Couldn't save: \(error.localizedDescription)"
                    }
                }))
                .disabled(catalog.enabled.isEmpty && !catalog.saveClaude)
            }
            RowDivider()
            Row(icon: "text.quote", title: "Prompt", detail: catalog.saveClaudeText == nil ? "Default" : "Custom") {
                Button("Edit…") { editingPrompt = true }
            }
        }
        .keepingCatalog($catalog)
        .sheet(isPresented: $editingPrompt) { SavingInstructionEditor(catalog: catalog) { catalog = AgentCatalog.load() } }
    }
}

/// Keeps a view's copy of the agents list current: it changes in this process and in `lastdrop --agents`.
private struct CatalogObserver: ViewModifier {
    @Binding var catalog: AgentCatalog

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .agentCatalogChanged)) { _ in catalog = AgentCatalog.load() }
            .onReceive(DistributedNotificationCenter.default().publisher(for: .agentCatalogChanged)) { _ in catalog = AgentCatalog.load() }
    }
}

extension View {
    func keepingCatalog(_ catalog: Binding<AgentCatalog>) -> some View { modifier(CatalogObserver(catalog: catalog)) }
}

/// The agents list with its editor.
struct AgentsSections: View {
    @Bindable var model: AppModel
    @State private var catalog = AgentCatalog.load()
    @State private var editing: AgentDefinition?
    @State private var error: String?

    var body: some View {
        Group {
            PageSection("Your agents",
                        info: "Extra models for the Agent tool, run on your other plans. Claude Code passes the name as model and picks one by its description. Changes apply from the next prompt.") {
                Button("New agent…") { editing = AgentDefinition(name: "", description: "", provider: .codex, model: "") }
            } content: {
                if catalog.agents.isEmpty {
                    Caption("No agents yet.").padding(.vertical, Design.rowPad)
                } else {
                    Nest { ForEach(catalog.agents) { row($0) } }
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.top, 6) }
            }
        }
        .keepingCatalog($catalog)
        .sheet(item: $editing) { agent in
            AgentEditor(agent: agent, catalog: catalog) { saved in
                change { next in
                    if let i = next.agents.firstIndex(where: { $0.id == saved.id }) { next.agents[i] = saved } else { next.agents.append(saved) }
                }
            }
        }
    }

    private func row(_ agent: AgentDefinition) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name).fontWeight(.medium)
                    Text("model: \"\(agent.name)\"").font(.caption.monospaced()).foregroundStyle(.tertiary)
                    InfoTip(agent.description)
                }
                AgentBadges(agent: agent)
                if let problem = model.agentProblem(agent.provider) {
                    Text(problem).font(.callout).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            RowSwitch(label: agent.name, isOn: Binding(get: { agent.enabled }, set: { on in change { next in
                if let i = next.agents.firstIndex(where: { $0.id == agent.id }) { next.agents[i].enabled = on }
            } }))
            Menu {
                Button("Edit…") { editing = agent }
                Divider()
                Button("Remove", role: .destructive) { change { $0.agents.removeAll { $0.id == agent.id } } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.vertical, 8)
    }

    /// Saves the list, which the plugin reads on the next prompt.
    private func change(_ edit: (inout AgentCatalog) -> Void) {
        do {
            try AgentCatalog.update(edit)
            catalog = AgentCatalog.load()
            error = nil
        } catch {
            self.error = "Couldn't save the agents: \(error.localizedDescription)"
        }
    }
}

/// When to stop sending agents to an account; only with a provider that has more than one to choose from.
struct AccountLimitsSection: View {
    @Bindable var model: AppModel

    private var hasChoice: Bool {
        AgentProvider.allCases.contains { ($0 == .claude || AgentPool.pools($0)) && model.accounts($0.usageID).count > 1 }
    }

    var body: some View {
        if model.agentsEnabled && hasChoice {
            PageSection("Account limits",
                        info: "Agents go to the provider's account with the most left, and skip one with less left than this. If every Codex, Z.ai or OpenRouter account is past this, the first one runs anyway. A Claude session never sends subagents to its own account.") {
                Row(icon: "clock", title: "Use until the session has") { threshold("Session", \.sessionThreshold) { model.setThresholds(session: $0) } }
                RowDivider()
                Row(icon: "calendar", title: "Use until the week has") { threshold("Week", \.weeklyThreshold) { model.setThresholds(weekly: $0) } }
            }
        }
    }

    private func threshold(_ title: String, _ key: KeyPath<AccountsConfig, Double>, set: @escaping (Double) -> Void) -> some View {
        Picker(title, selection: Binding(get: { model.accountsConfig[keyPath: key] }, set: set)) {
            // Stored as the share used, shown as what's left.
            ForEach([0.5, 0.75, 0.9, 0.95, 1], id: \.self) { Text("\(Int(((1 - $0) * 100).rounded()))% left").tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// Setup's suggested agents for the connected plans; each is checked against the provider's models when added.
struct SuggestedAgentsSection: View {
    @Bindable var model: AppModel
    @State private var catalog = AgentCatalog.load()
    @State private var adding: String?
    @State private var problems: [String: String] = [:]

    var body: some View {
        let suggestions = AgentSuggestions.available(catalog: catalog) { provider in
            !model.accounts(provider.usageID).isEmpty && model.agentProblem(provider) == nil
        }
        if !suggestions.isEmpty {
            PageSection("Suggested for your plans", info: "Ready-made agents for the plans you connected. Edit or remove them any time in Settings.") {
                Nest {
                    ForEach(suggestions) { agent in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(agent.name).fontWeight(.medium)
                                    InfoTip(agent.description)
                                }
                                AgentBadges(agent: agent)
                                if let problem = problems[agent.name] { Text(problem).font(.callout).foregroundStyle(.orange) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if adding == agent.name {
                                ProgressView().controlSize(.small)
                            } else {
                                Button("Add") { Task { await add(agent) } }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    /// Adds the agent once its provider still offers the model.
    private func add(_ agent: AgentDefinition) async {
        adding = agent.name
        defer { adding = nil }
        do {
            let models = try await agent.provider.models()
            guard models.isEmpty || models.contains(where: { $0.id == agent.model }) else {
                problems[agent.name] = "\(agent.provider.displayName) no longer offers \(agent.model)."
                return
            }
            var added = agent
            added.id = UUID()
            try AgentCatalog.update { $0.agents.append(added) }
            catalog = AgentCatalog.load()
            NotificationCenter.default.post(name: .agentCatalogChanged, object: nil)
        } catch {
            problems[agent.name] = "Couldn't check \(agent.provider.displayName)'s models: \(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    /// The agents list changed outside the view showing it.
    static let agentCatalogChanged = Notification.Name("LastDropAgentCatalogChanged")
    /// Open the menu bar panel, to show where lastdrop lives.
    static let showPanel = Notification.Name("LastDropShowPanel")
}
