import AppKit
import SwiftUI

/// `lastdrop --snapshots <folder>`: renders the panel, Settings, setup and the add-account sheet to PNGs with
/// the accounts on this Mac, offscreen, for reviewing the UI. Starts no status item and no warm pool, so it
/// runs beside the installed app.
@MainActor
enum Snapshots {
    static func main(to folder: URL) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // Light with LASTDROP_APPEARANCE=light; LASTDROP_GLASS=0 for the opaque stand-in.
        app.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["LASTDROP_APPEARANCE"] == "light" ? .aqua : .darkAqua)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        let demo = ProcessInfo.processInfo.environment["LASTDROP_DEMO"] == "1"
        if demo { model.loadDemo() } else { model.start() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(demo ? 1 : 10))   // usage and local checks
            func windowed(_ view: some View) -> some View {
                view.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea(edges: .top)
            }
            for page in SettingsPage.allCases {
                model.settingsPage = page
                await capture(windowed(SettingsView(model: model)), WindowPresenter.size, titled: "lastdrop", to: folder, "settings-\(page.rawValue)")
            }
            model.settingsPage = .accounts
            model.claudeError = "Claude Code refused: plugin lastdrop@lastdrop not found in marketplace."
            await capture(windowed(SettingsView(model: model)), WindowPresenter.size, titled: "lastdrop", to: folder, "settings-repair")
            model.claudeError = nil
            await capture(SavingInstructionEditor(catalog: AgentCatalog.load()) {}, nil, to: folder, "save-instruction")
            let demoAgent = AgentDefinition(name: "sol", description: "Reviews code, plans and diffs that need strong reasoning.", provider: .codex,
                                            model: "gpt-6.1-sol", effort: "high",
                                            fallbacks: [.init(provider: .antigravity, model: "gemini-4-argon", effort: "high"), .init(provider: .zai, model: "glm-5.3", effort: nil)])
            await capture(AgentEditor(agent: demoAgent, catalog: AgentCatalog()) { _ in }, nil, to: folder, "agent-editor")
            await capture(CommandJudgesSection(providers: AgentProvider.judged,
                                               judges: [.antigravity: AgentJudge(model: "gemini-4-argon", effort: "high")]) { _, _ in }
                .padding(24).frame(width: 640).background(Color(nsColor: .windowBackgroundColor)), nil, to: folder, "command-judges")
            model.panelTab = .limits
            await capture(PanelView(model: model), nil, to: folder, "panel-limits")
            model.settingsPage = .general
            for (name, phase) in [("available", Updater.Phase.available), ("downloading", .downloading), ("ready", .ready),
                                  ("failed", .failed("The download isn't signed by lastdrop's certificate"))] {
                model.updater.preview(phase, fraction: 0.42)
                await capture(PanelView(model: model), nil, to: folder, "panel-update-\(name)")
                await capture(windowed(SettingsView(model: model)), WindowPresenter.size, titled: "lastdrop", to: folder, "settings-update-\(name)")
            }
            model.updater.skip()
            model.settingsPage = .accounts
            model.panelTab = .agents
            await capture(PanelView(model: model), nil, to: folder, "panel-agents")
            // LASTDROP_STATS_DB shows a copy of a real index in place of the made-up usage.
            if let path = ProcessInfo.processInfo.environment["LASTDROP_STATS_DB"] { model.stats.loadForSnapshots(path: path) }
            model.panelTab = .stats
            for period in StatsPeriod.allCases {
                model.stats.pick(period)
                await capture(PanelView(model: model), nil, to: folder, "panel-stats-\(period.days)")
            }
            model.stats.pick(.week)
            if let bar = model.stats.page.bars.dropLast().last { model.stats.toggle(bar: bar.start) }
            await capture(PanelView(model: model), nil, to: folder, "panel-stats-day")
            if let bar = model.stats.selection.day { model.stats.toggle(bar: bar) }
            model.stats.open(project: model.stats.page.projects.first?.name)
            await capture(PanelView(model: model), nil, to: folder, "panel-stats-project")
            model.stats.open(project: nil)
            for step in SetupView.Step.allCases {
                await capture(windowed(SetupView(model: model, step: step)), WindowPresenter.size, titled: "lastdrop", to: folder, "setup-\(step.rawValue)")
            }
            let waiting = ConnectProvider(model: model, provider: .claude, back: {}, done: {}).frame(width: 440)
                .onAppear { model.connectStatus = .working("Finish signing in in your browser.") }
            await capture(waiting, nil, to: folder, "add-claude-waiting")
            model.connectStatus = .idle
            await capture(AddAccountSheet(model: model), nil, to: folder, "add-account")
            await capture(ConnectProvider(model: model, provider: .zai, back: {}, done: {}).frame(width: 440), nil, to: folder, "add-zai")
            exit(0)
        }
        app.run()
        exit(0)
    }

    private static func capture(_ view: some View, _ size: NSSize?, titled title: String? = nil, to folder: URL, _ name: String) async {
        let host = NSHostingController(rootView: view)
        if size != nil { host.sizingOptions = [] }
        var style: NSWindow.StyleMask = title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if title != nil { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 400), styleMask: style, backing: .buffered, defer: false)
        window.title = title ?? ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(size ?? host.view.fittingSize)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        if title != nil { TrafficLights.place(window) }
        try? await Task.sleep(for: .seconds(1.5))
        if size == nil { window.setContentSize(host.view.fittingSize); try? await Task.sleep(for: .seconds(0.5)) }
        guard let frameView = window.contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        // The window server's own picture: it has what SwiftUI keeps in layers (scroll views' content) and the glass, and a
        // process may ask for its own window without screen-recording permission, even off every screen.
        if let picture = windowPicture(window), picture.width > 0 {
            try? NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
            window.close()
            return
        }
        // Else render the layer tree.
        let scale = window.backingScaleFactor, bounds = frameView.bounds
        guard let layer = frameView.layer,
              let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(NSColor.windowBackgroundColor.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(origin: .zero, size: bounds.size))
        if !layer.isGeometryFlipped && frameView.isFlipped {
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
        window.close()
    }

    /// `CGWindowListCreateImage`, looked up at run time: the SDK marks it unavailable from macOS 15, which this targets,
    /// but it's still there, and nothing else pictures a window of this process without asking for permission.
    private static func windowPicture(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // .optionIncludingWindow, .boundsIgnoreFraming
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue()
    }
}
