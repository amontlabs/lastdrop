import AppKit
import SwiftUI

/// One provider in the menu bar: its logo, then each shown account's Session, Weekly, or both stacked, with
/// the account's name when there are several. Providers without those windows (OpenRouter) show their own
/// text, such as the credit balance.
struct MenuBarLabel: View {
    let group: MenuBarGroup
    /// Short of room: an account set to both shows Session alone.
    var squeezed = false

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: Logos.image(group.provider))
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 3) {
                    if let name = entry.name { tag(name) }
                    numbers(entry).fixedSize()
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.black)
        .frame(height: 22)
    }

    private func tag(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(lineWidth: 1))
            .fixedSize()
    }

    @ViewBuilder private func numbers(_ entry: MenuBarEntry) -> some View {
        let mode = squeezed && entry.mode == .both ? .session : entry.mode
        if entry.needsSignIn {
            Text("!").font(.system(size: 13, weight: .heavy))
        } else if let text = entry.snapshot?.menuBarText {
            Text(text).font(.system(size: 13, weight: .medium))
        } else {
            switch mode {
            case .session, .weekly:
                Text(Self.left(mode == .session ? "Session" : "Weekly", in: entry.snapshot))
                    .font(.system(size: 13, weight: .medium))
            case .both:
                VStack(alignment: .trailing, spacing: -1) {
                    Text(Self.left("Session", in: entry.snapshot))
                    Text(Self.left("Weekly", in: entry.snapshot))
                }
                .font(.system(size: 9, weight: .semibold))
            }
        }
    }

    static func left(_ label: String, in snapshot: UsageSnapshot?) -> String {
        guard let left = snapshot?.windows.first(where: { $0.label == label })?.remainingPercent else { return "–" }
        return "\(Int(left.rounded()))%"
    }

    /// Status item buttons take an image, and stacking needs two lines, so draw labels as a template.
    @MainActor static func template(_ view: some View) -> NSImage {
        let renderer = ImageRenderer(content: view)
        // Draw for the sharpest screen, not `NSScreen.main`: with a 1x external display active,
        // a 1x image would look pixelated on the Retina menu bar.
        renderer.scale = max(2, NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
        let image = renderer.nsImage ?? NSImage()
        image.isTemplate = true
        return image
    }
}
