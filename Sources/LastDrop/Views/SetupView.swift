import SwiftUI

/// First launch, in the window in place of Settings' sidebar and pages: one centered column, the same sections as
/// Settings, two steps. Get started hands over to the menu bar, opening the panel there.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var step: Step
    @State private var adding = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable {
        case accounts, agents, t3
        var name: String { switch self { case .accounts: "Accounts"; case .agents: "Agents"; case .t3: "T3 Code" } }

        /// The steps this Mac gets: T3 Code only when it is installed.
        static var available: [Step] { T3Settings.isInstalled ? allCases : [.accounts, .agents] }
    }

    init(model: AppModel, step: Step = .accounts) {
        self.model = model
        _step = State(initialValue: step)
    }

    static let doneKey = "setupDone"

    /// Shows setup on a fresh install. An install from before setup existed counts as set up.
    static func showIfNeeded(_ model: AppModel) {
        guard !model.defaults.bool(forKey: doneKey) else { return }
        if model.isFreshInstall { WindowPresenter.setup(model) } else { model.defaults.set(true, forKey: doneKey) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.sectionGap) {
                header
                Group {
                    switch step {
                    case .accounts:
                        AccountsSections(model: model, listsOthers: true)
                    case .agents:
                        AgentsSwitchSection(model: model)
                        if model.agentsEnabled {
                            SuggestedAgentsSection(model: model)
                            SaveClaudeSection()
                            AgentsSections(model: model)
                        }
                    case .t3:
                        T3ThreadsSection(titled: false)
                    }
                }
                .transition(.opacity)
            }
            .frame(maxWidth: Design.setupColumn, alignment: .leading)
            .padding(.horizontal, Design.pageInset)
            .padding(.top, 56)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: step)
        }
        .bottomBar { bar }
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppMark(size: 48)
            Text(step == .accounts ? "Welcome to lastdrop" : step == .agents ? "Agents" : "T3 Code")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 18)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            HStack {
                stepper
                Spacer()
                if step == .accounts {
                    Button("Add account…") { model.connectStatus = .idle; adding = true }
                }
            }
            .padding(.top, 24)
        }
    }

    private var subtitle: String {
        switch step {
        case .accounts: "See what's left of your AI plans. Logins on this Mac are already here."
        case .agents: "Optional. Run subagents on whichever Claude account has room, and hand work to your other plans."
        case .t3: "Optional. Start each T3 Code thread on the Claude account with the most room."
        }
    }

    /// "1 Accounts — 2 Agents": where you are, a check on what's done.
    private var stepper: some View {
        HStack(spacing: 8) {
            ForEach(Step.available, id: \.self) { item in
                if item.rawValue > 0 {
                    Capsule().fill(Design.ring).frame(width: 18, height: 1.5)
                }
                Button { step = item } label: {
                    HStack(spacing: 6) {
                        ZStack {
                            Circle().fill(item == step ? Color.accentColor : item.rawValue < step.rawValue ? Color.green : Color.primary.opacity(0.1))
                            if item.rawValue < step.rawValue {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Text("\(item.rawValue + 1)").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(item == step ? Color.white : .secondary)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(item.name).font(.callout.weight(item == step ? .medium : .regular))
                            .foregroundStyle(item == step ? .primary : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(item.rawValue + 1): \(item.name)")
            }
        }
    }

    // MARK: Bottom bar

    /// On glass, over the list scrolling under it: open at login, then Back and Continue.
    private var bar: some View {
        HStack(spacing: 10) {
            if step == .accounts {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!AppModel.isBundled)
            }
            Spacer()
            if step != .accounts {
                Button("Back") { move(-1) }.glassButton()
            }
            Button(step == Step.available.last ? "Get started" : "Continue") { move(1) }
                .glassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .frame(maxWidth: Design.setupColumn)
        .padding(.horizontal, Design.pageInset)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
    }

    private func move(_ offset: Int) {
        let next = step.rawValue + offset
        if let target = Step(rawValue: next), Step.available.contains(target) {
            step = target
        } else if next >= Step.available.count {
            finish()
        }
    }

    /// Setup is done: the window closes and the panel opens from the menu bar, where lastdrop lives from now on.
    private func finish() {
        model.defaults.set(true, forKey: Self.doneKey)
        model.settingUp = false
        WindowPresenter.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .showPanel, object: nil)
        }
    }
}

extension View {
    /// The system's glass buttons on macOS 26, its bordered ones before.
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *), Design.glass {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}
