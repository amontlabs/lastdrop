import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

/// The latest state of one provider section.
struct ProviderState: Sendable {
    var snapshot: UsageSnapshot?
    var error: String?
    var isLoading = false
    var lastAttempt: Date?
    var lastSuccess: Date?
    /// The provider has no login or key at all; its menu bar item is hidden.
    var notConfigured = false
    /// The last failure was a 429, so retrying sooner would only extend it.
    var rateLimited = false

    var retryDelay: TimeInterval {
        error == nil || rateLimited ? AppModel.refreshInterval : AppModel.retryInterval
    }

    func isStale(now: Date) -> Bool {
        guard let lastSuccess else { return false }
        return now.timeIntervalSince(lastSuccess) > AppModel.staleAfter
    }
}

/// Which window the menu bar items show.
enum MenuBarMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case session, weekly, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .both: "Both"
        }
    }
}

@MainActor @Observable
final class AppModel {
    nonisolated static let refreshInterval: TimeInterval = 5 * 60
    nonisolated static let retryInterval: TimeInterval = 60
    nonisolated static let staleAfter: TimeInterval = 10 * 60
    /// Opening the panel refreshes providers whose data is older than this.
    static let openThrottle: TimeInterval = 30
    static let alertWindows: Set<String> = ["Session", "Weekly"]
    /// Notifications and login items need a real app bundle, not `swift run`.
    static let isBundled = Bundle.main.bundleIdentifier != nil

    /// Each account's latest usage, by `Account.id`.
    private(set) var states: [String: ProviderState] = [:]
    /// Agents in Claude Code: lastdrop's plugin, subagents on other Claude accounts, and extra models for the Agent tool.
    /// Follows whether the plugin is installed.
    private(set) var agentsEnabled: Bool {
        didSet { defaults.set(agentsEnabled, forKey: "agentsEnabled") }
    }
    var panelTab = PanelTab.limits
    /// The Stats tab.
    let stats = StatsModel()
    private let launched = Date()
    var settingsPage = SettingsPage.accounts
    /// The window shows setup instead of Settings.
    var settingUp = false
    var order: [ProviderID] {
        didSet { defaults.set(order.map(\.rawValue), forKey: "providerOrder") }
    }
    private(set) var launchAtLogin = false
    private(set) var launchAtLoginError: String?
    // Accounts (AppModel+Accounts.swift)
    var localChecks: [String: LocalCheck] = [:]
    var connectStatus = ConnectStatus.idle
    /// The account added last, which the add-account sheet shows once it's done.
    var lastConnected: String?
    @ObservationIgnored var connectTask: Task<Void, Never>?
    /// Every provider's accounts, as saved; reloaded on each tick, since agent runners read it too.
    var accountsConfig = AccountsConfig.load()
    // Claude accounts (AppModel+Claude.swift)
    var claudeConfig: ClaudeAccountsConfig { ClaudeAccountsConfig(accountsConfig) }
    /// lastdrop's Claude Code plugin is installed and enabled (`~/.claude/settings.json`).
    var subagentsInstalled = false
    var claudeError: String?
    /// When lastdrop last started Claude Code to renew an account's expired sign-in.
    @ObservationIgnored var renewedAt: [String: Date] = [:]
    /// Plugin installs or removals still to finish; until then, its state says nothing about the feature.
    @ObservationIgnored private var pluginChanges = 0
    @ObservationIgnored private var pluginTask: Task<Void, Never>?

    let updater = Updater()
    /// Look for new releases by itself; Settings' Updates page turns it off.
    var checkUpdates: Bool {
        didSet { defaults.set(checkUpdates, forKey: "checkUpdates") }
    }
    /// The release "Skip" was chosen for: not offered again until a newer one, or until you check by hand.
    var skippedUpdate: String? {
        get { defaults.string(forKey: "skippedUpdate") }
        set { defaults.set(newValue, forKey: "skippedUpdate") }
    }

    /// Windows already announced; an entry clears once usage drops below the account's level.
    private var alerted: Set<String> {
        didSet { defaults.set(Array(alerted), forKey: "alertedLimits") }
    }
    let defaults = UserDefaults.standard
    private var loop: Task<Void, Never>?
    /// Nothing from an earlier run, judged before this run writes anything: first-launch setup shows.
    let isFreshInstall: Bool

    init() {
        // Any saved setting (older versions saved some only when changed) or file means it ran before.
        let earlier = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "lastdrop") ?? [:]
        isFreshInstall = earlier.isEmpty
            && !FileManager.default.fileExists(atPath: LastDropPaths.accounts.path)
            && !FileManager.default.fileExists(atPath: LastDropPaths.accountsConfig.path)
        let saved = (defaults.stringArray(forKey: "providerOrder") ?? []).compactMap(ProviderID.init)
        order = saved + ProviderID.allCases.filter { !saved.contains($0) }
        alerted = Set(defaults.stringArray(forKey: "alertedLimits") ?? [])
        checkUpdates = defaults.object(forKey: "checkUpdates") as? Bool ?? true
        agentsEnabled = SubagentInstaller.isInstalled() || SubagentInstaller.oldIsInstalled()
        if Self.isBundled { launchAtLogin = SMAppService.mainApp.status == .enabled }
        migrateAccountSettings()
    }

    /// Before each account had its own, the menu bar and notifications had one setting each: carry them over
    /// once, so an existing install looks as it did. A new install shows the icon alone and notifies at 100%.
    private func migrateAccountSettings() {
        guard !defaults.bool(forKey: "accountSettingsMigrated") else { return }
        let existing = !isFreshInstall
        let hidden = Set(defaults.stringArray(forKey: "disabledProviders") ?? [])
        let mode = MenuBarMode(rawValue: defaults.string(forKey: "menuBarMode") ?? "") ?? .session
        let modes = defaults.dictionary(forKey: "menuBarModes") as? [String: String] ?? [:]
        let notify = defaults.object(forKey: "notificationsOn") as? Bool ?? true
        updateAccounts { config in
            for account in config.accounts {
                config.update(account.id) { account in
                    // The menu bar showed each provider's main account, and every Claude account.
                    let shown = existing && !hidden.contains(account.provider.rawValue) && (account.isMain || account.provider == .claude)
                    account.menuBar = shown ? MenuBarMode(rawValue: modes[account.provider.rawValue] ?? "") ?? mode : nil
                    account.notifyAt = notify ? 1 : nil
                }
            }
        }
        defaults.set(true, forKey: "accountSettingsMigrated")
    }

    // MARK: Derived

    /// Whether the panel and Settings show anything about agents.
    var showsAgents: Bool { agentsEnabled }

    /// The provider's main account's usage.
    func state(_ id: ProviderID) -> ProviderState { state(of: .main(id)) }

    func state(of account: Account) -> ProviderState { states[account.id] ?? ProviderState() }

    /// Every account lastdrop reads: all of them, since agents need the limits even when the menu bar doesn't show them.
    var enabledAccounts: [Account] { order.flatMap { accountsConfig.pool($0) } }

    var lastUpdated: Date? { enabledAccounts.compactMap { states[$0.id]?.lastSuccess }.max() }

    var isRefreshing: Bool { enabledAccounts.contains { states[$0.id]?.isLoading == true } }

    /// The accounts the menu bar shows, by provider in the panel's order: those set to show something and
    /// with usage to show. Empty leaves the icon alone.
    var menuBarGroups: [MenuBarGroup] {
        connectedProviders.compactMap { provider in
            let shown = accounts(provider).filter { $0.account.menuBar != nil && $0.state.snapshot != nil }
            guard !shown.isEmpty else { return nil }
            return MenuBarGroup(provider: provider, entries: shown.map {
                MenuBarEntry(name: shown.count > 1 ? $0.name : nil, snapshot: $0.state.snapshot, mode: $0.account.menuBar ?? .session)
            })
        }
    }

    // MARK: Refresh

    func start() {
        guard loop == nil else { return }
        if accountsConfig.accounts.contains(where: { $0.notifyAt != nil }) { requestNotificationPermission() }
        // The plugin under the app's old name: replaced by this one's, which keeps agents on.
        if SubagentInstaller.oldIsInstalled() && !SubagentInstaller.isInstalled() { setAgents(true) }
        // This version's plugin, the first time it runs.
        if SubagentInstaller.isStale() { updatePlugin() }
        // The wrapper T3 Code points at, kept current with where this app's executable is.
        Task.detached { ThreadLauncher.writeWrapper() }
        refreshLocalChecks()
        loop = Task { [weak self] in
            var lastReaperCheck = Date.distantPast
            while !Task.isCancelled {
                await self?.refreshDue()
                await self?.claudeTick()
                self?.keepStatsCurrent()
                if Date().timeIntervalSince(lastReaperCheck) >= 20 {
                    lastReaperCheck = Date()
                    Task.detached { ThreadReaper.check() }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    /// Starts looking for new releases, and says once when one is ready to restart into.
    func startUpdates() {
        updater.automatic = { [weak self] in self?.checkUpdates ?? false }
        updater.skipped = { [weak self] in self?.skippedUpdate }
        updater.onSkip = { [weak self] in self?.skippedUpdate = $0 }
        updater.onReady = { [weak self] version in
            guard let self, defaults.string(forKey: "announcedUpdate") != version else { return }
            defaults.set(version, forKey: "announcedUpdate")
            post("lastdrop \(version) is ready. Open the panel to restart into it.", id: "update-\(version)")
        }
        updater.start()
    }

    /// Every 5 minutes, or 60 s after a failure.
    private func refreshDue() async {
        let now = Date()
        await refresh(enabledAccounts.filter { account in
            let s = state(of: account)
            guard let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= s.retryDelay
        })
    }

    func panelOpened() {
        let now = Date()
        let due = enabledAccounts.filter { account in
            let s = state(of: account)
            guard let last = s.lastAttempt else { return true }
            return now.timeIntervalSince(last) >= (s.error == nil ? Self.openThrottle : s.retryDelay)
        }
        Task { await refresh(due) }
        Task { await claudeTick() }
        refreshLocalChecks()
        refreshStats()
    }

    /// Reads new transcripts, unless that just happened.
    func refreshStats(after interval: TimeInterval = StatsModel.scanThrottle) {
        let names = Dictionary(accountsConfig.accounts.map { ($0.id, statsName($0)) }) { first, _ in first }
        stats.refresh(accounts: { id in names[id] ?? Self.statsName(id: id) }, after: interval)
    }

    /// In the background, not while the app is starting up.
    private func keepStatsCurrent() {
        guard Date().timeIntervalSince(launched) > 30 else { return }
        refreshStats(after: StatsModel.backgroundInterval)
    }

    private func statsName(_ account: Account) -> String {
        let detail = account.name ?? state(of: account).snapshot?.plan
        return [account.provider.displayName, detail].compactMap { $0 }.joined(separator: " ")
    }

    /// An account no longer in lastdrop: "claude.Pro" → "Claude Pro".
    nonisolated static func statsName(id: String) -> String {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        let provider = ProviderID(rawValue: parts[0])?.displayName ?? parts[0]
        return parts.count == 2 && parts[1] != Account.mainKey ? "\(provider) \(parts[1])" : provider
    }

    func refreshAll() {
        Task { await refresh(enabledAccounts) }
    }

    /// Every account of these providers.
    func refresh(_ ids: [ProviderID]) async {
        await refresh(ids.flatMap { accountsConfig.pool($0) })
    }

    func refresh(_ accounts: [Account]) async {
        let accounts = accounts.filter { states[$0.id]?.isLoading != true }
        await withTaskGroup(of: Void.self) { group in
            for account in accounts { group.addTask { await self.refreshOne(account) } }
        }
    }

    private func refreshOne(_ account: Account) async {
        let id = account.id
        states[id, default: ProviderState()].isLoading = true
        states[id]?.lastAttempt = .now
        do {
            let snapshot = try await fetch(account)
            states[id]?.snapshot = snapshot   // keep the last good data on failure
            states[id]?.error = nil
            states[id]?.notConfigured = false
            states[id]?.rateLimited = false
            states[id]?.lastSuccess = .now
            checkLimits(account, snapshot)
        } catch {
            states[id]?.error = error.localizedDescription
            if case ProviderError.notConfigured = error { states[id]?.notConfigured = true }
            if case ProviderError.rateLimited = error { states[id]?.rateLimited = true }
        }
        states[id]?.isLoading = false
    }

    private func fetch(_ account: Account) async throws -> UsageSnapshot {
        do {
            return try await account.usageProvider.fetch()
        } catch ProviderError.unauthorized where account.provider == .claude && !account.isMain
                    && Date().timeIntervalSince(renewedAt[account.key] ?? .distantPast) > 600 {
            // Unused for a while: Claude Code renews the sign-in when started.
            renewedAt[account.key] = Date()
            guard let renewed = await ClaudeSignIn.renew(ClaudeAccount(id: account.key)) else {
                throw ProviderError.unauthorized("Claude Code sign-in expired. Run `claude` to refresh it.")
            }
            return renewed
        }
    }

    // MARK: Settings

    /// Turning agents on installs lastdrop's Claude Code plugin; turning them off removes it.
    func setAgents(_ on: Bool) {
        agentsEnabled = on
        claudeError = nil
        pluginChanges += 1
        // One install or removal at a time, each toward the latest choice, so quick toggles end where they stopped.
        let previous = pluginTask
        pluginTask = Task {
            await previous?.value
            let want = agentsEnabled
            if want != SubagentInstaller.isInstalled() {
                do {
                    try await want ? SubagentInstaller.install() : SubagentInstaller.uninstall()
                } catch {
                    claudeError = error.localizedDescription
                }
            }
            pluginChanges -= 1
            syncPlugin()
        }
    }

    /// The plugin is what makes agents work, so the feature follows it, also when it was changed in Claude Code.
    func syncPlugin() {
        guard pluginChanges == 0 else { return }
        let installed = SubagentInstaller.isInstalled()
        if installed != subagentsInstalled { subagentsInstalled = installed }
        if installed != agentsEnabled { agentsEnabled = installed }
    }

    /// Something lastdrop can fix itself: the plugin failed to install or update.
    var needsRepair: Bool { claudeError != nil }

    /// Installs the plugin again, from this copy of the app.
    func repair() {
        claudeError = nil
        pluginChanges += 1
        let previous = pluginTask
        pluginTask = Task {
            await previous?.value
            do {
                try await SubagentInstaller.install()
                agentsEnabled = true
            } catch {
                claudeError = error.localizedDescription
            }
            pluginChanges -= 1
            syncPlugin()
        }
    }

    /// Brings the plugin to this version of the app, unless agents were turned off meanwhile.
    private func updatePlugin() {
        pluginChanges += 1
        let previous = pluginTask
        pluginTask = Task {
            await previous?.value
            if agentsEnabled {
                do {
                    try await SubagentInstaller.update()
                } catch {
                    claudeError = error.localizedDescription
                }
            }
            pluginChanges -= 1
            syncPlugin()
        }
    }

    func setMenuBar(_ id: String, _ mode: MenuBarMode?) { updateAccounts { $0.update(id) { $0.menuBar = mode } } }

    func setNotify(_ id: String, _ level: Double?) {
        updateAccounts { $0.update(id) { $0.notifyAt = level } }
        if level != nil { requestNotificationPermission() }
    }

    func move(_ id: ProviderID, by offset: Int) {
        guard let i = order.firstIndex(of: id), order.indices.contains(i + offset) else { return }
        order.swapAt(i, i + offset)
    }

    /// Made-up accounts and usage for screenshots and the video (`LASTDROP_DEMO=1` with `--snapshots`): nothing is read
    /// from or written to this Mac's accounts.
    func loadDemo() {
        let now = Date()
        func w(_ label: String, _ used: Double, _ hours: Double) -> UsageWindow {
            UsageWindow(label: label, usedPercent: used, resetsAt: now.addingTimeInterval(hours * 3600))
        }
        var config = AccountsConfig()
        config.update("claude.main") { $0.menuBar = .both }
        config.append(Account(provider: .claude, key: "work", name: "Team", menuBar: .both))
        config.update("codex.main") { $0.menuBar = .both }
        config.update("zai.main") { $0.menuBar = .session }
        config.update("antigravity.main") { $0.notifyAt = 0.9 }
        accountsConfig = config
        let usage: [String: UsageSnapshot] = [
            "claude.main": UsageSnapshot(title: "Claude", plan: "Max 20x", windows: [w("Session", 81, 1.8), w("Weekly", 46, 92), w("Fable Weekly", 30, 92)]),
            "claude.work": UsageSnapshot(title: "Claude", plan: "Team", windows: [w("Session", 12, 4.2), w("Weekly", 23, 121)]),
            "codex.main": {
                var s = UsageSnapshot(title: "Codex", plan: "Pro 200", windows: [w("Session", 34, 3.1), w("Weekly", 18, 140)])
                s.credits = ExtraCredits(amount: "12,480 credits", detail: "About 3,100 to 16,200 messages")
                return s
            }(),
            "antigravity.main": UsageSnapshot(title: "Antigravity", plan: "Ultra", windows: [w("Session", 8, 4.6), w("Weekly", 15, 110)]),
            "zai.main": UsageSnapshot(title: "Z.ai", plan: "GLM Coding Pro", windows: [w("Session", 21, 2.4), w("Weekly", 37, 70)]),
            "openrouter.main": UsageSnapshot(title: "OpenRouter", plan: nil, windows: [UsageWindow(label: "Credits", usedPercent: 38, detail: "$124.00 of $200.00 left")],
                                             menuBarText: "$124"),
        ]
        for (id, snapshot) in usage {
            states[id] = ProviderState(snapshot: snapshot, lastAttempt: now, lastSuccess: now)
        }
        let emails = ["claude.main": "you@example.com", "claude.work": "you@company.com", "antigravity.main": "you@example.com"]
        localChecks = Dictionary(uniqueKeysWithValues: config.accounts.map { ($0.id, LocalCheck(connected: true, email: emails[$0.id], agents: .ready)) })
        agentsEnabled = true
        subagentsInstalled = true
        launchAtLogin = true
        stats.loadDemo()
    }

    /// Snapshots only: shows Settings with agents off or on, without touching the plugin.
    func previewAgents(_ on: Bool) { agentsEnabled = on }

    /// Drops what a removed account showed.
    func forgetUsage(_ account: Account) { states[account.id] = nil }

    func setLaunchAtLogin(_ on: Bool) {
        guard Self.isBundled else { return }
        do {
            try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Notifications

    /// One notification each time a Session or Weekly limit crosses the account's level.
    func checkLimits(_ account: Account, _ snapshot: UsageSnapshot) {
        let saved = accountsConfig.account(account.id) ?? account
        for window in snapshot.windows where Self.alertWindows.contains(window.label) {
            guard let used = window.usedPercent else { continue }
            let key = "\(account.provider.rawValue)\(account.isMain ? "" : ".\(account.key)").\(window.label)"
            guard let level = saved.notifyAt, used >= level * 100 else { alerted.remove(key); continue }
            if alerted.insert(key).inserted {
                let name = displayName(saved, plan: snapshot.plan)
                notify(Self.alertText(provider: account.provider, name: account.isMain ? nil : name, window: window, used: used), id: key)
            }
        }
    }

    /// "Codex Session limit reached, resets at 14:00", or "Claude (Pro) Weekly: 10% left, resets …".
    static func alertText(provider: ProviderID, name: String?, window: UsageWindow, used: Double) -> String {
        var text = "\(provider.displayName)\(name.map { " (\($0))" } ?? "") \(window.label)"
        text += used >= 100 ? " limit reached" : ": \(Int((100 - used).rounded()))% left"
        if let reset = window.resetsAt { text += ", resets at \(Format.clock(reset))" }
        return text
    }

    private func notify(_ text: String, id: String) { post(text, id: id) }

    func post(_ text: String, id: String) {
        guard Self.isBundled else { return }
        let content = UNMutableNotificationContent()
        content.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func requestNotificationPermission() {
        guard Self.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = NotificationPresenter.shared
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

/// Shows banners even while the panel is open and the app is active.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// One provider in the menu bar: its logo, then each shown account's numbers.
struct MenuBarGroup {
    var provider: ProviderID
    var entries: [MenuBarEntry]
}

struct MenuBarEntry {
    /// Set when the provider shows several accounts, to tell them apart.
    var name: String?
    var snapshot: UsageSnapshot?
    var mode: MenuBarMode
}
