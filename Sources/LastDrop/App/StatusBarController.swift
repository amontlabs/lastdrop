import AppKit
import Observation
import SwiftUI

/// A single status item showing every provider side by side, opening one panel.
@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let popover = NSPopover()
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    /// Provider strips from fullest to smallest; the first that fits is shown. Empty when no provider
    /// has anything to show.
    private var strips: [NSImage] = []
    private lazy var gauge: NSImage? = BrandImages.menuBarGlyph()
    /// macOS hid a strip this wide at the item's current right edge, so only narrower ones are tried there.
    private var hiddenWidth = CGFloat.infinity
    private var rightEdge: CGFloat?
    private var hiddenCheck: Task<Void, Never>?

    init(model: AppModel) {
        self.model = model
        super.init()
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        item.button?.setAccessibilityLabel("lastdrop")
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(itemMoved(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(showPanel), name: .showPanel, object: nil)
        observe()
    }

    private func observe() {
        withObservationTracking { update() } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    /// The accounts set to show something, by provider; the plain icon when none is. With less room, accounts drop
    /// from the end, each still showing what it's set to: Both stacks two small numbers, no wider than one big one,
    /// so showing Session alone instead saves nothing.
    private func update() {
        let groups = model.menuBarGroups
        let count = groups.reduce(0) { $0 + $1.entries.count }
        var layouts = [(groups, false)]
        layouts += (1..<max(count, 1)).reversed().map { (Self.first($0, of: groups), false) }
        strips = groups.isEmpty ? [] : layouts.map { strip($0.0, squeezed: $0.1) }
        layout()
    }

    /// The first `count` accounts across the groups, in order.
    static func first(_ count: Int, of groups: [MenuBarGroup]) -> [MenuBarGroup] {
        var left = count
        return groups.compactMap { group in
            guard left > 0 else { return nil }
            var group = group
            group.entries = Array(group.entries.prefix(left))
            left -= group.entries.count
            return group
        }
    }

    private func strip(_ groups: [MenuBarGroup], squeezed: Bool) -> NSImage {
        MenuBarLabel.template(HStack(spacing: 10) {
            ForEach(groups, id: \.provider) { MenuBarLabel(group: $0, squeezed: squeezed) }
        })
    }

    /// macOS hides a status item that doesn't fit, beside the notch or the app's menus, without telling the
    /// app, so show the fullest strip that fits, or the gauge. Beside the notch, the room gives a first guess;
    /// macOS keeps a margin of its own, so a strip it still hides is dropped for the next smaller one. Items keep
    /// their right edge as their width changes, which measures the room without flickering, and a new right edge
    /// means the room changed, so every strip is tried again.
    private func layout() {
        guard let button = item.button else { return }
        let window = button.window
        if let edge = window?.frame.maxX, edge != rightEdge {
            rightEdge = edge
            hiddenWidth = .infinity
        }
        var room = hiddenWidth
        // The area beside the notch runs to the screen's right edge; its width avoids guessing its coordinates.
        if let window, let screen = window.screen, let area = screen.auxiliaryTopRightArea, area.width > 0 {
            let padding = window.frame.width - (button.image?.size.width ?? 0)
            room = min(room, window.frame.maxX - padding - (screen.frame.maxX - area.width) + 0.5)
        }
        let image = strips.first { $0.size.width < room } ?? gauge
        if button.image !== image { button.image = image }
        checkHidden()
    }

    /// Once macOS has placed the item, drop to a narrower strip if it hid this one.
    private func checkHidden() {
        hiddenCheck?.cancel()
        guard let image = item.button?.image, image !== gauge else { return }
        hiddenCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let window = item.button?.window, item.button?.image === image,
                  Self.isHidden(window.frame, in: Self.statusWindows()) else { return }
            hiddenWidth = image.size.width
            layout()
        }
    }

    /// The status windows on the window server, as (frame, on screen). Status items are drawn by another
    /// process, so their window numbers don't match; frames do, and reading them needs no permission.
    static func statusWindows() -> [(CGRect, Bool)] {
        let level = Int(CGWindowLevelForKey(.statusWindow))
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == level,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { return nil }
            return (frame, info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
    }

    /// Whether the window server holds a status window at this frame's place and width, none of them on screen.
    /// Only x and width are compared: the window server measures y from the top.
    static func isHidden(_ frame: CGRect, in windows: [(CGRect, Bool)]) -> Bool {
        let matches = windows.filter { abs($0.0.minX - frame.minX) < 1 && abs($0.0.width - frame.width) < 1 }
        return !matches.isEmpty && !matches.contains { $0.1 }
    }

    @objc private func itemMoved(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === item.button?.window else { return }
        layout()
    }

    @objc private func screensChanged() {
        hiddenWidth = .infinity
        layout()
    }

    /// After setup: open the panel, to show where lastdrop lives.
    @objc private func showPanel() {
        guard !popover.isShown, let button = item.button else { return }
        toggle(button)
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) { model.panelOpened() }
}
