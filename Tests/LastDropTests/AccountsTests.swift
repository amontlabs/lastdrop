import XCTest
@testable import LastDrop

final class AccountsTests: LastDropTestCase {
    private func keys(_ config: AccountsConfig, _ provider: ProviderID) -> [String] { config.pool(provider).map(\.key) }

    // MARK: Accounts

    func testEveryProviderHasOneMainAccount() {
        let config = AccountsConfig()
        for provider in ProviderID.allCases { XCTAssertEqual(keys(config, provider), ["main"]) }
    }

    func testWhereEachAccountKeepsItsLogin() {
        for provider in ProviderID.allCases {
            XCTAssertNil(Account.main(provider).folder)
            XCTAssertEqual(Account.main(provider).keychainItem("zai-api-key"), "zai-api-key")
        }
        XCTAssertTrue(Account(provider: .claude, key: "Pro").folder!.hasSuffix("/.claude-accounts/Pro"))
        XCTAssertTrue(Account(provider: .codex, key: "work").folder!.hasSuffix("/.codex-accounts/work"))
        XCTAssertNil(Account(provider: .zai, key: "work").folder)
        XCTAssertEqual(Account(provider: .zai, key: "work").keychainItem("zai-api-key"), "zai-api-key.work")
        XCTAssertEqual(Account(provider: .codex, key: "work").id, "codex.work")
        // Claude accounts keep the folders they had before pools.
        XCTAssertEqual(ClaudeAccount(id: "Pro").cliConfigDir, Account(provider: .claude, key: "Pro").folder)
    }

    func testAddingGoesToTheEndOfItsOwnPool() {
        var config = AccountsConfig()
        XCTAssertEqual(config.add(.codex, name: "work")?.id, "codex.work")
        XCTAssertEqual(config.add(.claude, name: "my pro")?.key, "my-pro")
        XCTAssertEqual(config.add(.codex, name: "home")?.id, "codex.home")
        XCTAssertEqual(keys(config, .codex), ["main", "work", "home"])
        XCTAssertEqual(keys(config, .claude), ["main", "my-pro"])
        let claudeEnd = config.accounts.lastIndex { $0.provider == .claude }!
        XCTAssertEqual(config.accounts.firstIndex { $0.provider == .codex }, claudeEnd + 1)
    }

    func testAddingRefusesUnusableAndTakenNames() {
        var config = AccountsConfig()
        XCTAssertNil(config.add(.zai, name: "../"))
        XCTAssertNil(config.add(.zai, name: "Main"))
        XCTAssertNotNil(config.add(.zai, name: "work"))
        XCTAssertNil(config.add(.zai, name: "Work"))
        XCTAssertNotNil(config.add(.codex, name: "work"), "names are per provider")
    }

    func testMovingStaysInsideThePool() {
        var config = AccountsConfig()
        _ = config.add(.codex, name: "a")
        _ = config.add(.zai, name: "x")
        _ = config.add(.codex, name: "b")
        config.move("codex.b", by: -1)
        XCTAssertEqual(keys(config, .codex), ["main", "b", "a"])
        config.move("codex.main", by: 1)
        XCTAssertEqual(keys(config, .codex), ["b", "main", "a"])
        config.move("codex.b", by: -1)   // already first
        XCTAssertEqual(keys(config, .codex), ["b", "main", "a"])
        XCTAssertEqual(keys(config, .zai), ["main", "x"])
    }

    func testMainAccountsCantBeRemoved() {
        var config = AccountsConfig()
        _ = config.add(.openrouter, name: "team")
        config.remove("openrouter.main")
        config.remove("openrouter.team")
        XCTAssertEqual(keys(config, .openrouter), ["main"])
    }

    func testNormalizeDropsDuplicatesAndRestoresMain() throws {
        let json = #"{"accounts":[{"provider":"codex","key":"a","addedAt":1},{"provider":"codex","key":"a","addedAt":2}],"weeklyThreshold":0.5}"#
        let config = try JSONDecoder.lastdrop.decode(AccountsConfig.self, from: Data(json.utf8))
        XCTAssertEqual(keys(config, .codex), ["main", "a"])
        XCTAssertEqual(config.pool(.codex)[1].addedAt, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(config.weeklyThreshold, 0.5)
        XCTAssertEqual(config.sessionThreshold, AccountsConfig.defaultThreshold)
        XCTAssertEqual(keys(config, .zai), ["main"])
    }

    @MainActor func testRemovingAnAccountOnlyTouchesItsOwnProvidersKeys() {
        XCTAssertEqual(AppModel.ownItems(.zai).map(\.item), [ZAIProvider.sessionAccount, ZAIProvider.keyAccount])
        XCTAssertEqual(AppModel.ownItems(.openrouter).map(\.item), [OpenRouterProvider.keyAccount])
        XCTAssertEqual(AppModel.ownItems(.antigravity).map(\.item), [AntigravityProvider.loginAccount])
        XCTAssertTrue(AppModel.ownItems(.claude).isEmpty, "Claude Code keeps its own login")
        XCTAssertTrue(AppModel.ownItems(.codex).isEmpty, "the Codex CLI keeps its own login")
    }

    // MARK: Migration and files

    private let legacyJSON = #"""
    {"accounts":[{"id":"Pro","addedAt":100},{"id":"Team","addedAt":200}],"order":["Pro","main","Team"],
     "sessionThreshold":0.75,"weeklyThreshold":0.95}
    """#

    func testMigratingTheOldClaudeListKeepsItsOrderAndThresholds() throws {
        let old = try JSONDecoder.lastdrop.decode(ClaudeAccountsConfig.self, from: Data(legacyJSON.utf8))
        let config = AccountsConfig(migrating: old)
        XCTAssertEqual(keys(config, .claude), ["Pro", "main", "Team"])
        XCTAssertEqual(config.pool(.claude)[0].addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(config.sessionThreshold, 0.75)
        XCTAssertEqual(config.weeklyThreshold, 0.95)
        for provider in ProviderID.allCases where provider != .claude { XCTAssertEqual(keys(config, provider), ["main"]) }
        // The runners' view of it is the old list.
        let claude = ClaudeAccountsConfig(config)
        XCTAssertEqual(claude.order, old.order)
        XCTAssertEqual(claude.accounts, old.accounts)
        XCTAssertEqual(claude.sessionThreshold, 0.75)
    }

    func testLoadMigratesUntilSavedThenReadsItsOwnFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("accounts.json"), legacy = dir.appendingPathComponent("claude-accounts.json")

        XCTAssertEqual(AccountsConfig.load(from: url, legacy: legacy), AccountsConfig())
        try Data(legacyJSON.utf8).write(to: legacy)
        var config = AccountsConfig.load(from: url, legacy: legacy)
        XCTAssertEqual(keys(config, .claude), ["Pro", "main", "Team"])

        config.append(Account(provider: .codex, key: "work", addedAt: Date(timeIntervalSince1970: 300)))   // whole seconds survive JSON
        try config.save(to: url)
        XCTAssertEqual(AccountsConfig.load(from: url, legacy: legacy), config)
        XCTAssertEqual(try Data(contentsOf: legacy), Data(legacyJSON.utf8), "the old file stays as it was")
    }

    func testReplacingTheClaudePoolLeavesOtherProvidersAlone() {
        var config = AccountsConfig()
        _ = config.add(.codex, name: "work")
        var claude = ClaudeAccountsConfig(config)
        claude.accounts.append(ClaudeAccount(id: "Pro"))
        claude.order = ["Pro", "main"]
        claude.weeklyThreshold = 0.5
        config.replaceClaudePool(with: claude)
        XCTAssertEqual(keys(config, .claude), ["Pro", "main"])
        XCTAssertEqual(keys(config, .codex), ["main", "work"])
        XCTAssertEqual(config.weeklyThreshold, 0.5)
        XCTAssertEqual(config.accounts.first?.provider, .claude, "the Claude pool keeps its place")
    }

    // MARK: Menu bar and notifications

    func testNewAccountsNotifyAtTheLimitAndShowNothing() throws {
        let fresh = Account(provider: .codex, key: "work")
        XCTAssertNil(fresh.menuBar)
        XCTAssertEqual(fresh.notifyAt, 1)
        // Saved before these settings existed: the app's one-time migration fills them in.
        let old = try JSONDecoder.lastdrop.decode(Account.self, from: Data(#"{"provider":"codex","key":"work","addedAt":1}"#.utf8))
        XCTAssertNil(old.menuBar)
        XCTAssertNil(old.notifyAt)
    }

    func testSavingTheClaudeListKeepsEachAccountsSettings() {
        var config = AccountsConfig()
        config.append(Account(provider: .claude, key: "Pro", name: "Work", menuBar: .both, notifyAt: 0.9))
        config.replaceClaudePool(with: ClaudeAccountsConfig(config))
        let pro = config.account("claude.Pro")
        XCTAssertEqual(pro?.name, "Work")
        XCTAssertEqual(pro?.menuBar, .both)
        XCTAssertEqual(pro?.notifyAt, 0.9)
    }

    @MainActor func testAlertsSayHowFarAlong() {
        let window = UsageWindow(label: "Weekly", usedPercent: 90.4)
        XCTAssertEqual(AppModel.alertText(provider: .claude, name: "Pro", window: window, used: 90.4), "Claude (Pro) Weekly: 10% left")
        XCTAssertEqual(Account.notifyTitle(0.9), "10% left")
        XCTAssertEqual(Account.notifyTitle(1), "Used up")
        XCTAssertEqual(AppModel.alertText(provider: .codex, name: nil, window: window, used: 100), "Codex Weekly limit reached")
    }

    @MainActor func testShortOfRoomTheMenuBarDropsAccountsFromTheEnd() {
        let entry = MenuBarEntry(name: nil, snapshot: nil, mode: .session)
        let groups = [MenuBarGroup(provider: .claude, entries: [entry, entry]), MenuBarGroup(provider: .codex, entries: [entry])]
        XCTAssertEqual(StatusBarController.first(3, of: groups).map(\.entries.count), [2, 1])
        XCTAssertEqual(StatusBarController.first(2, of: groups).map(\.entries.count), [2])
        XCTAssertEqual(StatusBarController.first(1, of: groups).map(\.entries.count), [1])
    }

    @MainActor func testTheMenuBarKnowsWhenMacOSHidItsItem() {
        let item = CGRect(x: 1148, y: 1290, width: 394, height: 39)
        let shown = CGRect(x: 1542, y: 0, width: 109, height: 39)
        // The window server measures y from the top, so only x and width have to match.
        let hidden = CGRect(x: 1148, y: 0, width: 394, height: 39)
        XCTAssertEqual(StatusBarController.isShown(item, in: [(shown, true), (hidden, false)]), false)
        XCTAssertEqual(StatusBarController.isShown(item, in: [(hidden, true)]), true)
        XCTAssertNil(StatusBarController.isShown(item, in: [(shown, false)]), "not found means not known")
    }
}
