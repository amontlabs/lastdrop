import AppKit
import SwiftUI

/// What the panel shows. Agents only while agents are on.
enum PanelTab: String, CaseIterable {
    case limits = "Limits"
    case agents = "Agents"
    case stats = "Stats"
}

struct PanelView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: Binding { tab } set: { model.panelTab = $0 }) {
                ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 10)
            // Never taller than the space under the menu bar, or macOS shifts the popover.
            CappedScroll(maxHeight: (NSScreen.main?.visibleFrame.height ?? 800) - 120) {
                Group {
                    if tab == .stats {
                        // Outside the timeline: nothing here changes with the clock.
                        StatsPanel(stats: model.stats)
                            .task {
                                while !Task.isCancelled {
                                    model.refreshStats()
                                    try? await Task.sleep(for: .seconds(StatsModel.scanThrottle))
                                }
                            }
                    } else {
                        TimelineView(.periodic(from: .now, by: 5)) { context in
                            if tab == .limits {
                                LimitsList(model: model, now: context.date)
                            } else {
                                AgentsPanel(model: model, now: context.date)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            Divider()
            if model.updater.showsInPanel {
                UpdateBanner(updater: model.updater)
                Divider()
            }
            footer
        }
        .frame(width: 320)
        .tint(Brand.accent)
    }

    private var tabs: [PanelTab] {
        PanelTab.allCases.filter { $0 != .agents || model.showsAgents }
    }

    private var tab: PanelTab {
        tabs.contains(model.panelTab) ? model.panelTab : .limits
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(action: model.refreshAll) {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isRefreshing)
            }
            .keyboardShortcut("r")
            .help("Refresh (⌘R)")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(updatedText(now: context.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { WindowPresenter.settings(model) } label: { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .keyboardShortcut("q")
                .help("Quit lastdrop")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func updatedText(now: Date) -> String {
        guard let last = model.lastUpdated else { return model.isRefreshing ? "Updating…" : "Not updated yet" }
        if now.timeIntervalSince(last) < 60 { return "Updated just now" }
        return "Updated \(Format.clock(last, now: now))"
    }
}

/// Every connected account, grouped by provider, two meters each.
struct LimitsList: View {
    let model: AppModel
    let now: Date

    var body: some View {
        let providers = model.connectedProviders
        if providers.isEmpty {
            EmptyPanel(text: "No accounts yet.", action: "Add an Account…") { WindowPresenter.settings(model, page: .accounts) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(providers) { provider in
                    ProviderGroup(provider: provider, accounts: model.accounts(provider), now: now)
                }
            }
        }
    }
}

private struct EmptyPanel: View {
    let text: String
    let action: String
    let perform: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(text).foregroundStyle(.secondary)
            Button(action, action: perform)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

/// A provider's name and logo, then its accounts. A single account sits on the provider's own line.
private struct ProviderGroup: View {
    let provider: ProviderID
    let accounts: [AccountInfo]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if accounts.count == 1, let only = accounts.first {
                AccountRow(info: only, title: provider.displayName, logo: provider, now: now)
            } else {
                HStack(spacing: 7) {
                    ProviderLogo(id: provider, size: 14)
                    Text(provider.displayName).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                ForEach(accounts) { info in
                    AccountRow(info: info, title: info.name, logo: nil, now: now)
                }
            }
        }
    }
}

/// One account: name and plan, then Session and Weekly side by side. Hovering shows every limit it has.
private struct AccountRow: View {
    let info: AccountInfo
    let title: String
    /// The provider's logo, when the row stands for the whole provider.
    let logo: ProviderID?
    let now: Date
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let logo { ProviderLogo(id: logo, size: 14) } else { Spacer().frame(width: 14) }
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let plan = info.plan, plan != title { PlanChip(text: plan) }
                ResetBadge(resets: info.state.snapshot?.resets, now: now)
                Spacer(minLength: 4)
                status
            }
            content.padding(.leading, 20)
            if let credits = info.state.snapshot?.credits {
                CreditsLine(credits: credits).padding(.leading, 20)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hovering = $0 }
        .hoverTip { AccountDetail(info: info, now: now) }
    }

    @ViewBuilder private var status: some View {
        if info.state.isLoading {
            ProgressView().controlSize(.mini)
        } else if info.state.isStale(now: now) {
            Text("Outdated").font(.caption2).foregroundStyle(.orange)
        } else if info.state.error != nil, info.state.snapshot != nil {
            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        } else if info.isNext {
            Text("Next").font(.caption2.weight(.semibold)).foregroundStyle(Brand.accent)
                .help(info.account.provider != .claude ? "New \(info.account.provider.displayName) agents run on this account: it has the most room."
                      : info.account.isMain ? "New subagents run on this account: no other account has room."
                      : "New subagents run on this account: of the accounts your sessions don't use, it has the most room.")
        }
    }

    @ViewBuilder private var content: some View {
        if let snapshot = info.state.snapshot {
            let main = ProviderSection.split(snapshot.windows).main
            if main.count == 1, let only = main.first {
                CompactMeter(window: only, now: now)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(main.prefix(2), id: \.label) { CompactMeter(window: $0, now: now) }
                }
            }
        } else if let error = info.state.error {
            Caption(error)
        } else {
            Caption("Loading…")
        }
    }
}

/// What the account spends past its limits, and whether it's spending it now.
private struct CreditsLine: View {
    let credits: ExtraCredits

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "creditcard").foregroundStyle(.secondary)
            Text(credits.amount).monospacedDigit()
            if credits.inUse {
                Text("In use").font(.caption2.weight(.semibold)).foregroundStyle(Brand.accent)
            }
        }
        .font(.caption)
    }
}

/// "Session 91%", a thin bar of what's left, and when it resets.
private struct CompactMeter: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(window.label).foregroundStyle(.secondary)
                ResetBadge(resets: window.resets, now: now)
                Spacer(minLength: 4)
                Text(window.detail ?? Format.left(window)).monospacedDigit()
            }
            .font(.caption)
            Meter(remaining: window.remainingPercent ?? 0, height: 4)
            if let reset = window.resetsAt {
                Text(Format.resets(reset, now: now)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The hover card: every limit, and the per-key spend for OpenRouter.
private struct AccountDetail: View {
    let info: AccountInfo
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.headline)
                if let email = info.email { Caption(email) }
            }
            if let snapshot = info.state.snapshot {
                ForEach(snapshot.windows, id: \.label) { WindowRow(window: $0, now: now) }
                if let credits = snapshot.credits {
                    VStack(alignment: .leading, spacing: 2) {
                        CreditsLine(credits: credits)
                        Caption(credits.inUse ? "The limits are used up: this is what it runs on now." : "Spent once a limit is used up.")
                        if let detail = credits.detail { Caption(detail) }
                    }
                }
                if !snapshot.keys.isEmpty {
                    Divider()
                    ForEach(snapshot.keys.prefix(6), id: \.self) { KeyRow(key: $0) }
                }
            }
            if let error = info.state.error { Caption(error) }
        }
        .padding(12)
        .frame(width: 260)
    }
}

/// Saving Claude usage, what runs on your other accounts and plans now, and the agents list.
struct AgentsPanel: View {
    let model: AppModel
    let now: Date

    var body: some View {
        let catalog = AgentCatalog.load()
        let running = AgentRegistry.runningNow()
        VStack(alignment: .leading, spacing: 12) {
            SaveClaudeToggle(catalog: catalog)
            Divider()
            if !running.isEmpty {
                section("Running") {
                    ForEach(running, id: \.id) { item in
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.entry.definition?.name ?? item.entry.subagentType ?? "Subagent").font(.subheadline.weight(.medium)).lineLimit(1)
                                Caption("\(place(item.entry)) · \(Format.duration(now.timeIntervalSince(item.entry.at)))")
                            }
                        }
                    }
                }
            }
            section("Your agents") {
                if catalog.agents.isEmpty {
                    Caption("No agents yet. Add them in Settings.")
                }
                ForEach(catalog.agents) { agent in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name).font(.subheadline.weight(.medium))
                            AgentBadges(agent: agent, compact: true).help(agent.summary)
                            if let problem = model.agentProblem(agent.provider) {
                                Text(problem).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { agent.enabled }, set: { on in
                            try? AgentCatalog.update { next in
                                if let i = next.agents.firstIndex(where: { $0.id == agent.id }) { next.agents[i].enabled = on }
                            }
                        }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                    }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// "Pro", "Codex · Work": the account an agent runs on, by its name in the panel.
    private func place(_ entry: AgentRegistry.Entry) -> String {
        if let id = entry.accountID, let account = model.accountsConfig.account(id) {
            return AgentPool.place(account, name: model.displayName(account, plan: model.state(of: account).snapshot?.plan))
        }
        return model.accounts(.claude).first { $0.account.key == entry.account }?.name ?? entry.account
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// "Save Claude usage" as a panel row, its switch in line with the agents' below.
struct SaveClaudeToggle: View {
    let catalog: AgentCatalog

    static let about = "Claude plans and checks the work, and hands coding, searching and research to your agents on other plans."

    var body: some View {
        HStack(spacing: 6) {
            Text("Save Claude usage").font(.subheadline.weight(.medium))
            InfoTip(catalog.enabled.isEmpty ? "Add an agent first." : Self.about)
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { catalog.saveClaude }, set: { on in
                try? AgentCatalog.update { $0.saveClaude = on }
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(catalog.enabled.isEmpty && !catalog.saveClaude)
        }
    }
}

/// The text Save Claude usage adds to every prompt, which the user can rewrite or reset.
struct SavingInstructionEditor: View {
    let catalog: AgentCatalog
    let saved: () -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("Prompt").font(.title3.weight(.semibold))
                InfoTip("Added to every prompt in Claude Code while Save Claude usage is on. Changes apply from the next prompt.")
            }
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .frame(minHeight: 150)
            HStack {
                Button("Reset to default") { text = AgentCatalog.defaultSavingInstruction }
                    .disabled(text == AgentCatalog.defaultSavingInstruction)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    try? AgentCatalog.update { $0.saveClaudeText = trimmed.isEmpty || trimmed == AgentCatalog.defaultSavingInstruction ? nil : trimmed }
                    saved()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { text = catalog.savingInstruction }
    }
}

enum ProviderSection {
    /// Session and Weekly show by default; a provider with neither (OpenRouter) shows everything.
    static func split(_ windows: [UsageWindow]) -> (main: [UsageWindow], more: [UsageWindow]) {
        let main = windows.filter { $0.label == "Session" || $0.label == "Weekly" }
        return main.isEmpty ? (windows, []) : (main, windows.filter { !main.contains($0) })
    }
}

/// A small ↺ and the number of limit resets the account can spend, in a header line; hovering lists when
/// each one expires. Nothing when there are none.
struct ResetBadge: View {
    let resets: LimitResets?
    let now: Date

    var body: some View {
        if let resets = resets?.current(now: now), resets.count > 0 {
            HStack(spacing: 1) {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 9, weight: .semibold))
                Text("\(resets.count)").font(.caption2.weight(.medium)).monospacedDigit()
            }
            .foregroundStyle(.secondary)
            .hoverTip { ResetDetail(resets: resets, now: now) }
            .accessibilityLabel(Self.tooltip(resets, now: now))
        }
    }

    /// "2 limit resets to spend. Expire in 3d 4h (Tue 14:30) and in 10d (Nov 5 09:00)."
    static func tooltip(_ resets: LimitResets, now: Date) -> String {
        var text = resets.count == 1 ? "1 limit reset to spend." : "\(resets.count) limit resets to spend."
        let dates = resets.expiries.map { "in \(Format.duration($0.timeIntervalSince(now))) (\(Format.clock($0, now: now)))" }
        if !dates.isEmpty {
            // Several resets ending together read once, with a count.
            var grouped: [(String, Int)] = []
            for d in dates { if grouped.last?.0 == d { grouped[grouped.count - 1].1 += 1 } else { grouped.append((d, 1)) } }
            let parts = grouped.map { $1 > 1 ? "\($1) \($0)" : $0 }
            let list = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
            text += (dates.count == 1 ? " Expires " : " Expire ") + list + "."
        }
        return text
    }
}

/// The resets badge's hover card: how many, then when each expires.
struct ResetDetail: View {
    let resets: LimitResets
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(.tint)
                Text(resets.count == 1 ? "1 limit reset" : "\(resets.count) limit resets").font(.headline)
            }
            if groups.isEmpty {
                Text("No expiry date given.").font(.callout).foregroundStyle(.secondary)
            } else {
                Divider()
                ForEach(groups, id: \.date) { group in
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.count > 1 ? "\(group.count) expire in \(Format.duration(group.date.timeIntervalSince(now)))"
                                             : "Expires in \(Format.duration(group.date.timeIntervalSince(now)))")
                        Spacer(minLength: 12)
                        Text(when(group.date)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .frame(width: 240)
    }

    /// "jeu. 21:42" within a week; past that a weekday alone is ambiguous, so the date ("7 nov. 01:32").
    private func when(_ date: Date) -> String {
        date.timeIntervalSince(now) < 6 * 86400 ? Format.clock(date, now: now)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// Resets that end at the same moment, counted once.
    private var groups: [(date: Date, count: Int)] {
        var out: [(date: Date, count: Int)] = []
        for date in resets.expiries {
            if out.last?.date == date { out[out.count - 1].count += 1 } else { out.append((date, 1)) }
        }
        return out
    }
}

extension View {
    /// Shows `text` in a small popover while the pointer is over the view. `.help` tooltips don't
    /// appear in the panel: it belongs to a menu bar app whose window is never the active one.
    func hoverTip(_ text: String) -> some View {
        hoverTip {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 260, alignment: .leading)
                .padding(12)
        }
    }

    func hoverTip<Tip: View>(@ViewBuilder _ tip: @escaping () -> Tip) -> some View { modifier(HoverTip(tip: tip)) }
}

private struct HoverTip<Tip: View>: ViewModifier {
    let tip: () -> Tip
    @State private var shown = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onHover { inside in
                pending?.cancel()
                // A short delay, like a system tooltip, so passing over the badge doesn't flash it.
                pending = Task { @MainActor in
                    if inside { try? await Task.sleep(for: .milliseconds(350)) }
                    guard !Task.isCancelled else { return }
                    shown = inside
                }
            }
            .popover(isPresented: $shown, arrowEdge: .bottom) { tip() }
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(window.label).font(.subheadline)
                ResetBadge(resets: window.resets, now: now)
                Spacer()
                Text(Format.left(window))
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Meter(remaining: window.remainingPercent ?? 0)
            if let reset = window.resetsAt {
                Text(Format.resets(reset, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Spend on one API key; keys with a limit get a meter of what is left of it.
struct KeyRow: View {
    let key: KeyUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(key.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(key.disabled ? .secondary : .primary)
                Spacer()
                Text(Format.dollars(key.total)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
            }
            if let limit = key.limit, limit > 0 {
                let left = key.limitRemaining ?? max(limit - key.total, 0)
                Meter(remaining: left / limit * 100)
                Text("\(Format.dollars(left)) of \(Format.dollars(limit)) left").font(.caption).foregroundStyle(.secondary)
            }
            if let periods = periods {
                Text(periods).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var periods: String? {
        let parts = [key.today.map { "Today \(Format.dollars($0))" }, key.month.map { "This month \(Format.dollars($0))" }]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Fills with what is left: blue, yellow at 20% left, red at 10% left.
struct Meter: View {
    let remaining: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geo.size.width * min(max(remaining, 0), 100) / 100)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: remaining)
    }

    private var color: Color {
        remaining <= 10 ? .red : remaining <= 20 ? .orange : Brand.accent
    }
}

/// A scroll view as tall as its content, up to `maxHeight`; beyond that it scrolls.
struct CappedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content
                .background(GeometryReader { geo in
                    Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        // A legacy scrollbar (shown with a mouse attached) would take width and shift everything over
        // whenever the content grows past the cap; the wheel and trackpad still scroll.
        .scrollIndicators(.never)
        .frame(height: min(contentHeight, maxHeight))
        .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension ProviderID {
    /// Each provider's usual brand colors; two for a gradient.
    var brandColors: [Color] {
        switch self {
        case .claude: [Color(hex: 0xD97757), Color(hex: 0xC15F3C)]          // Anthropic terracotta
        case .codex: [Color(hex: 0x10A37F), Color(hex: 0x0D8A6B)]           // OpenAI green
        case .antigravity: [Color(hex: 0x4285F4), Color(hex: 0x9B72CB)]     // Gemini blue to purple
        case .zai: [Color(hex: 0x2563EB), Color(hex: 0x1E40AF)]             // Z.ai blue
        case .openrouter: [Color(hex: 0x6467F2), Color(hex: 0x4F46E5)]      // OpenRouter indigo
        }
    }

    /// A soft wash of the brand colors that keeps text readable in light and dark mode.
    var brandBackground: LinearGradient {
        LinearGradient(colors: [brandColors[0].opacity(0.20), brandColors[1].opacity(0.07)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
