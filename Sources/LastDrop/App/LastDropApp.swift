import AppKit

@main
enum Entry {
    static func main() {
        // First of all, before any other flag check: T3's own arguments are full of flags (`--print`,
        // `--verbose`), and the launcher must never be mistaken for one of them.
        if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--claude-thread" {
            ThreadLauncher.main(Array(CommandLine.arguments.dropFirst(2)))
        }
        // T3 Code's "lastdrop" ACP provider: stdout carries JSON-RPC only, and AppKit never starts.
        if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--acp" { ACPServer.main() }
        Rename.migrate()
        if CommandLine.arguments.contains("--agent-key") { EndpointProfile.keyMain() }
        if CommandLine.arguments.contains("--print") { printUsage(); return }
        if CommandLine.arguments.contains("--agent-run") { AgentRun.main() }
        if CommandLine.arguments.contains("--agent-route") { AgentRun.main(routeOnly: true) }
        if CommandLine.arguments.contains("--agent-warm") { AgentRun.warmMain() }
        if CommandLine.arguments.contains("--agent-open") { AgentRun.openMain() }
        if CommandLine.arguments.contains("--agent-stop") { AgentRun.stopMain() }
        if CommandLine.arguments.contains("--agent-selftest") { SelfTest.main() }
        if CommandLine.arguments.contains("--agent-catalog") { AgentCatalog.printMain() }
        if CommandLine.arguments.contains("--delegate-note") { DelegateNotes.main() }
        if CommandLine.arguments.contains("--agents") { AgentsCommand.main() }
        if let i = CommandLine.arguments.firstIndex(of: "--update"), i + 1 < CommandLine.arguments.count {
            UpdateCheck.main(as: CommandLine.arguments[i + 1], install: CommandLine.arguments.contains("--install"))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--app-icon"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { BrandImages.writeIconSet(to: URL(fileURLWithPath: CommandLine.arguments[i + 1])) }
            exit(0)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshots"), i + 1 < CommandLine.arguments.count {
            Snapshots.main(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // the bundle sets LSUIElement; this covers `swift run` too
        app.run()
    }

    /// `lastdrop --print`: fetch every account once and print the result, for debugging.
    private static func printUsage() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for account in AccountsConfig.load().accounts {
                let name = account.provider.displayName + (account.isMain ? "" : " · \(account.key)")
                do {
                    let s = try await account.usageProvider.fetch()
                    print("\(name) [\(s.plan ?? "no plan")]")
                    for w in s.windows {
                        let reset = w.resetsAt.map { Format.resets($0) } ?? "no reset"
                        print("  \(w.label): \(Format.left(w)), \(reset)")
                    }
                    if let c = s.credits { print("  Credits: \(c.amount)\(c.inUse ? " (in use)" : "")\(c.detail.map { ", \($0)" } ?? "")") }
                } catch {
                    print("\(name): \(error.localizedDescription)")
                }
            }
            done.signal()
        }
        done.wait()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        model.start()
        model.startUpdates()
        self.model = model
        NSApp.mainMenu = Self.mainMenu()
        statusBar = StatusBarController(model: model)
        SetupView.showIfNeeded(model)
        WarmPoolServer.shared.start()
    }

    /// Text fields only get ⌘V, ⌘C, ⌘A and undo through an Edit menu; the menus show while a window is open.
    private static func mainMenu() -> NSMenu {
        let menu = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            item.submenu = sub
            menu.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("lastdrop", [item("Quit lastdrop", #selector(NSApplication.terminate(_:)), "q")])
        submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        return menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        WarmPoolServer.shared.stop()
    }
}
