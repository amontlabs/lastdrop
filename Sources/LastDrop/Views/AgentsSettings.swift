import SwiftUI

/// Adding or editing one agent, in a sheet: its name and role, then its models by priority.
struct AgentEditor: View {
    @State var agent: AgentDefinition
    let catalog: AgentCatalog
    let save: (AgentDefinition) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var chain: [AgentFallback]
    @State private var error: String?

    init(agent: AgentDefinition, catalog: AgentCatalog, save: @escaping (AgentDefinition) -> Void) {
        _agent = State(initialValue: agent)
        _chain = State(initialValue: agent.chain)
        self.catalog = catalog
        self.save = save
    }

    private var isNew: Bool { !catalog.agents.contains { $0.id == agent.id } }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $agent.name, prompt: Text("reviewer"))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Description")
                        TextField("Description", text: $agent.description,
                                  prompt: Text("Reviews code, plans and diffs that need strong reasoning."), axis: .vertical)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .lineLimit(2...4)
                    }
                } footer: {
                    HStack(spacing: 4) {
                        Caption("Claude uses it as model: \"\(AgentDefinition.slug(agent.name))\" on the Agent tool.")
                        InfoTip("Claude picks agents by their description, so write it for Claude.")
                    }
                }
                Section {
                    ForEach($chain) { $entry in
                        let index = chain.firstIndex { $0.id == entry.id } ?? 0
                        ModelRow(entry: $entry, index: index, count: chain.count,
                                 move: { chain.move(entry.id, by: $0) },
                                 remove: { chain.removeAll { $0.id == entry.id } })
                    }
                    Button("Add model") { chain.append(AgentFallback(provider: .codex, model: "", effort: nil)) }
                } header: {
                    Text("Models")
                } footer: {
                    Caption("Tried in order. The next one runs only if the one above can't start, never once work has begun.")
                }
            }
            .formStyle(.grouped)
            HStack {
                if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add agent" : "Save", action: commit).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 620, height: min(380 + CGFloat(chain.count) * 44, 640))
    }

    private func commit() {
        var next = agent
        next.chain = chain
        next.name = AgentDefinition.slug(next.name)
        next.description = next.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = catalog.problem(with: next) { error = problem; return }
        save(next)
        dismiss()
    }
}

/// One line of an agent's models: its place in the order, provider, model and effort, and buttons to move or remove it.
private struct ModelRow: View {
    @Binding var entry: AgentFallback
    let index: Int
    let count: Int
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var models: [AgentModel] = []
    @State private var modelsError: String?

    /// The selected model's efforts; every level when the model isn't in the provider's list.
    private var efforts: [String] {
        models.first { $0.id == entry.model }?.efforts ?? (entry.model.isEmpty ? [] : ClaudeBackend.efforts)
    }

    private var modelName: String {
        models.first { $0.id == entry.model }?.name ?? (entry.model.isEmpty ? "Choose…" : entry.model)
    }

    private func logo(_ provider: AgentProvider) -> Image { Image(nsImage: Logos.colored(provider.usageID, size: 13)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("\(index + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 12, alignment: .leading)
                ColumnMenu {
                    ForEach(AgentProvider.allCases) { provider in
                        // A new provider has other models: the reset belongs to this choice, not to a change of the row.
                        Button { entry.provider = provider; entry.model = ""; entry.effort = nil } label: {
                            logo(provider)
                            Text(provider.displayName)
                        }
                    }
                } label: {
                    logo(entry.provider)
                    Text(entry.provider.displayName)
                }
                .frame(width: 128)
                Group {
                    if models.isEmpty {
                        TextField("Model", text: $entry.model, prompt: Text("Model id")).labelsHidden().textFieldStyle(.plain)
                    } else {
                        ColumnMenu {
                            ForEach(models) { model in
                                Button(model.name) {
                                    entry.model = model.id
                                    if let effort = entry.effort, !model.efforts.contains(effort) { entry.effort = nil }
                                }
                            }
                        } label: {
                            Text(modelName)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if !efforts.isEmpty {
                        ColumnMenu {
                            Button("Auto") { entry.effort = nil }
                            ForEach(efforts, id: \.self) { effort in Button(effort.capitalized) { entry.effort = effort } }
                        } label: {
                            Text(entry.effort?.capitalized ?? "Auto")
                        }
                    }
                }
                .frame(width: 76, alignment: .leading)
                HStack(spacing: 4) {
                    Button { move(-1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).help("Move up")
                    Button { move(1) } label: { Image(systemName: "chevron.down") }.disabled(index == count - 1).help("Move down")
                    Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.disabled(count == 1).help("Remove")
                }
                .buttonStyle(.borderless)
                .frame(width: 66, alignment: .trailing)
            }
            if let modelsError { Caption(modelsError) }
        }
        .task(id: entry.provider) { await loadModels() }
    }

    private func loadModels() async {
        models = []
        modelsError = nil
        do {
            models = try await entry.provider.backend.models()
            if models.isEmpty { modelsError = "\(entry.provider.displayName) lists no models here: type the model's id." }
        } catch {
            modelsError = "Couldn't list \(entry.provider.displayName)'s models (\(error.localizedDescription)). Type the model's id."
        }
    }
}

/// A menu that fills its column: its label starts at the column's left edge and its chevron ends at the right,
/// so rows line up whatever they show. A `Picker` sizes to its content instead.
private struct ColumnMenu<Items: View, Label: View>: View {
    @ViewBuilder let items: () -> Items
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu(content: items) {
            HStack(spacing: 6) {
                label().lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

/// Settings → Agents → Command judges: the model that checks each judged provider's agents' commands.
struct CommandJudgesSection: View {
    let providers: [AgentProvider]
    let judges: [AgentProvider: AgentJudge]
    let save: (AgentProvider, AgentJudge?) -> Void

    var body: some View {
        PageSection("Command judges") {
            Caption(JudgeRow.about).padding(.bottom, 4)
            Nest {
                ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                    if index > 0 { RowDivider() }
                    JudgeRow(provider: provider, chosen: judges[provider]) { save(provider, $0) }
                }
            }
        }
    }
}

/// One provider's command judge: the default or a model from the provider's live list, and Antigravity's effort.
/// A judge the provider no longer offers stays chosen and is flagged: lastdrop never swaps in another model.
struct JudgeRow: View {
    let provider: AgentProvider
    /// The user's choice; nil is the default.
    let chosen: AgentJudge?
    let save: (AgentJudge?) -> Void
    @State private var models: [AgentModel] = []
    @State private var modelsError: String?
    @State private var typed = ""

    static let about = "A model checks each command an agent wants to run and refuses risky ones. A weak model lets risky commands through: glm-5.3-flash allowed an SSH-key upload that glm-5.3 blocked."

    private var defaultName: String {
        provider.defaultJudge.map { "Default (\($0.summary))" } ?? "Default (the agent's own model)"
    }

    private var current: AgentJudge? { chosen ?? provider.defaultJudge }

    private var efforts: [String] {
        guard provider.judgeTakesEffort, let model = current?.model else { return [] }
        return models.first { $0.id == model }?.efforts ?? AntigravityBackend.efforts
    }

    /// The chosen judge isn't in the provider's list: its agents' checked commands fail until another is chosen.
    private var missing: String? {
        guard let judge = current, !models.isEmpty else { return nil }
        guard let model = models.first(where: { $0.id == judge.model }) else {
            return "\(provider.displayName) doesn't offer \(judge.model): checked commands will fail until you choose another judge."
        }
        if let effort = judge.effort, !model.efforts.isEmpty, !model.efforts.contains(effort) {
            return "\(judge.model) doesn't take \(effort) effort: checked commands will fail until you choose another."
        }
        return nil
    }

    private func name(_ id: String) -> String { models.first { $0.id == id }?.name ?? id }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(nsImage: Logos.colored(provider.usageID, size: 13)).frame(width: 22)
                Text(provider.displayName).frame(width: 96, alignment: .leading)
                Group {
                    if models.isEmpty {
                        TextField("Judge model", text: $typed, prompt: Text(defaultName))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .onSubmit { pick(typed.trimmingCharacters(in: .whitespaces)) }
                    } else {
                        ColumnMenu {
                            Button(defaultName) { save(nil) }
                            Divider()
                            ForEach(models) { model in Button(model.name) { pick(model.id) } }
                        } label: {
                            Text(chosen.map { name($0.model) } ?? defaultName)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if !efforts.isEmpty {
                        ColumnMenu {
                            Button("Auto") { save(AgentJudge(model: current!.model, effort: nil)) }
                            ForEach(efforts, id: \.self) { effort in
                                Button(effort.capitalized) { save(AgentJudge(model: current!.model, effort: effort)) }
                            }
                        } label: {
                            Text(current?.effort?.capitalized ?? "Auto")
                        }
                    }
                }
                .frame(width: 76, alignment: .leading)
            }
            if let missing { Text(missing).font(.callout).foregroundStyle(.orange) }
            if let modelsError { Caption(modelsError) }
        }
        .padding(.vertical, 8)
        .task(id: provider) { await loadModels() }
        .onAppear { typed = chosen?.model ?? "" }
        .onChange(of: chosen) { typed = chosen?.model ?? "" }
    }

    /// Keeps the effort when the new model takes it; Antigravity's default effort otherwise.
    private func pick(_ id: String) {
        guard !id.isEmpty else { save(nil); return }
        var effort: String?
        if provider.judgeTakesEffort {
            let offered = models.first { $0.id == id }?.efforts ?? AntigravityBackend.efforts
            let wanted = current?.effort ?? provider.defaultJudge?.effort
            effort = wanted.flatMap { offered.contains($0) ? $0 : nil }
        }
        save(AgentJudge(model: id, effort: effort))
    }

    private func loadModels() async {
        models = []
        modelsError = nil
        do {
            models = try await provider.backend.models()
            if models.isEmpty { modelsError = "\(provider.displayName) lists no models here: type the judge's model id." }
        } catch {
            modelsError = "Couldn't list \(provider.displayName)'s models (\(error.localizedDescription)). Type the judge's model id."
        }
    }
}
