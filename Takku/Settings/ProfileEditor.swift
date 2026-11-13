import AppKit
import TakkuCore
import SwiftUI

struct ProfileRow: View {
    let profile: ProviderProfile
    let isActive: Bool
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "pencil.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            VStack(alignment: .leading) {
                Text(profile.displayName)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                Text("In use").font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var caption: String {
        if profile.isTakkuCredit { return String(localized: "Prepaid credit") }
        if profile.isAppleIntelligence { return String(localized: "On this Mac") }
        switch profile.agentCLI {
        case .codex: return String(localized: "Your ChatGPT plan, through Codex")
        case .copilot: return String(localized: "Your GitHub Copilot plan")
        case .claude: return String(localized: "Your Claude plan, through Claude Code")
        case .opencode: return String(localized: "Your plan, through OpenCode")
        case .pi: return String(localized: "Your plan, through Pi")
        case nil: break
        }
        return profile.model.isEmpty ? String(localized: "To be configured") : profile.model
    }
}

struct ProfileEditor: View {
    @Binding var profile: ProviderProfile
    let isActive: Bool
    let activate: () -> Void
    @State private var apiKey = ""
    /// Last characters of the saved key, so the user can tell which key is stored; `nil` if none.
    @State private var storedKeySuffix: String?
    @State private var status: String?
    @State private var isTesting = false
    /// The Extra parameters as typed: they reach the Profile only when valid.
    @State private var extraParameters = ""
    @State private var extraParametersProblem: String?
    /// Takku Credit only: the balance read from the gateway, and why it could not be read.
    @State private var credit: TakkuCredit.Balance?
    @State private var creditProblem: String?
    @State private var isReadingCredit = false
    /// Agent CLIs only: why the CLI cannot be used now (not installed, not signed in), `nil` when it can.
    @State private var cliProblem: String?
    /// Agent CLIs only: the models the agent offers, `nil` when they could not be read.
    @State private var agentModels: [AgentCLI.Model]?
    /// Agent CLIs only: the model is typed (*Other…*) rather than chosen in the menu.
    @State private var typesModel = false
    /// Agent CLIs only: the executable Takku runs and its version, to tell two installs apart.
    @State private var cliInstall: (path: String, version: String?)?

    var body: some View {
        Section {
            if profile.isTakkuCredit {
                creditRows
            } else if profile.isAppleIntelligence {
                appleIntelligenceRows
            } else if let cli = profile.agentCLI {
                agentCLIRows(cli)
            } else {
                providerRows
            }

            // The only place where the key is entered. It is saved on Return, Save key, Test
            // connection or Use for Summaries, never while typing: a stray keystroke must not replace a working key.
            if !profile.isAppleIntelligence && profile.agentCLI == nil { LabeledContent("API key") {
                HStack {
                    PasteableTextField(
                        placeholder: storedKeySuffix.map { String(localized: "Saved in the Keychain (…\($0)) · paste here to replace it") }
                            ?? String(localized: "Paste the key here"),
                        text: $apiKey,
                        isSecure: true,
                        onSubmit: saveKey
                    )
                    if !apiKey.isEmpty {
                        Button("Save key", action: saveKey)
                    } else if storedKeySuffix != nil {
                        Button("Remove", role: .destructive) {
                            Keychain.deleteAPIKey(for: profile.id)
                            storedKeySuffix = nil
                            credit = nil
                            status = String(localized: "Key removed.")
                        }
                    }
                }
            } }

            HStack {
                Button("Test connection") { Task { await test() } }
                    .disabled(isTesting || profile.baseURL.isEmpty || (profile.model.isEmpty && profile.agentCLI?.hasDefaultModel != true) || extraParametersProblem != nil)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                if isActive {
                    Text("Used for Summaries").foregroundStyle(.green)
                } else {
                    Button("Use for Summaries") { if saveKeyIfNeeded(announce: true) { activate() } }
                }
            }
            if let status {
                Text(status).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("Profile: \(profile.displayName)")
        } footer: {
            Group {
                if profile.isAppleIntelligence || profile.agentCLI != nil {
                    Text("Changes are saved as you type.")
                } else {
                    Text("Changes are saved as you type. The key goes to the Keychain when you press Return, Save key or Test connection.")
                }
            }
            .foregroundStyle(.secondary)
        }
        .onAppear {
            refreshStoredKey()
            extraParameters = profile.extraParameters ?? ""
            Task { await readCredit() }
            Task { await checkAgentCLI() }
        }
        // Back from the browser after paying: the new balance without pressing anything.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readCredit() }
            // Back from Terminal after the CLI's login.
            Task { await checkAgentCLI() }
        }
    }

    /// Apple Intelligence has nothing to configure: the model and its context are the system's.
    @ViewBuilder private var appleIntelligenceRows: some View {
        Text("Apple Intelligence's model, on this Mac: free, and nothing leaves the Mac. It is a small model, so long meetings are summarised in more parts and the Summaries are shorter and less precise than with a large model.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if let unavailability = AppleIntelligenceModel.unavailability {
            Text(unavailability.localizedDescription).foregroundStyle(.orange)
        }
    }

    /// An agent CLI needs no key: it is the user's own, signed in with their plan. Only the model
    /// and how much it reasons can change; an empty model is the agent's own default.
    @ViewBuilder private func agentCLIRows(_ cli: AgentCLI) -> some View {
        Group {
            switch cli {
            case .codex:
                Text("Uses your ChatGPT plan through Codex, with no API key. The Transcript and your notes go to OpenAI under your plan's terms; each run has no tools, session or settings.")
            case .copilot:
                Text("Uses your GitHub Copilot plan (counts toward premium requests), with no API key. The Transcript and your notes go to GitHub and its model providers; each run has no tools, session or settings.")
            case .claude:
                Text("Uses your Claude plan through Claude Code, with no API key. The Transcript and your notes go to Anthropic under your plan's terms; each run has no tools, session or settings.")
            case .opencode:
                Text("Uses the plan you signed in to in OpenCode, with no API key. The Transcript and your notes go to the model's provider; each run has no tools or settings, and Takku deletes its session afterwards.")
            case .pi:
                Text("Uses the plan you signed in to in Pi, with no API key. The Transcript and your notes go to the model's provider; each run has no tools, session, extensions or skills.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if let groups = providerGroups {
            groupedModelMenu(cli, groups)
        } else {
            Picker("Model", selection: modelChoice(cli)) {
                if cli.hasDefaultModel {
                    Text("\(cli.name)'s default model").tag(ModelChoice.agentDefault)
                } else if profile.model.isEmpty && !typesModel {
                    Text("Choose a model").tag(ModelChoice.unset)
                }
                ForEach(agentModels ?? [], id: \.name) { model in
                    Text(verbatim: model.name).tag(ModelChoice.named(model.name))
                }
                Text("Other…").tag(ModelChoice.other)
            }
        }
        if modelChoice(cli).wrappedValue == .other {
            LabeledContent("Model name") {
                PasteableTextField(placeholder: String(localized: "As \(cli.name) names it"), text: $profile.model)
            }
        } else if cli.hasDefaultModel && profile.model.isEmpty {
            Text("\(cli.name)'s own default, not the model chosen in your \(cli.name) settings: Takku does not read them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let levels = cli.reasoningLevels(for: profile.model, in: agentModels) {
            Picker("Reasoning", selection: $profile.reasoning) {
                Text("Model default").tag(ProviderProfile.ReasoningEffort?.none)
                ForEach(levels, id: \.self) { effort in
                    Text(effort.displayName).tag(ProviderProfile.ReasoningEffort?.some(effort))
                }
            }
            .disabled(levels.isEmpty)
            .onChange(of: levels, initial: true) {
                // A level the new model refuses would make every Summary fail.
                if let reasoning = profile.reasoning, !levels.contains(reasoning) { profile.reasoning = nil }
            }
        }
        if let cliProblem {
            Text(cliProblem).foregroundStyle(.orange).textSelection(.enabled)
        } else if let cliInstall {
            Group {
                if let version = cliInstall.version {
                    Text("Runs \(cliInstall.path), version \(version).")
                } else {
                    Text("Runs \(cliInstall.path).")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    private enum ModelChoice: Hashable {
        case agentDefault, named(String), other, unset
    }

    /// OpenCode's and Pi's `provider/model` lists run to hundreds: one submenu per provider.
    private var providerGroups: [(provider: String, models: [AgentCLI.Model])]? {
        guard let models = agentModels, models.count > 20, models.allSatisfy({ $0.name.contains("/") }) else { return nil }
        return Dictionary(grouping: models) { String($0.name.prefix { $0 != "/" }) }
            .sorted { $0.key < $1.key }
            .map { (provider: $0.key, models: $0.value) }
    }

    @ViewBuilder private func groupedModelMenu(_ cli: AgentCLI, _ groups: [(provider: String, models: [AgentCLI.Model])]) -> some View {
        let choice = modelChoice(cli)
        LabeledContent("Model") {
            Menu {
                if cli.hasDefaultModel {
                    Button("\(cli.name)'s default model") { choice.wrappedValue = .agentDefault }
                }
                ForEach(groups, id: \.provider) { group in
                    Menu(group.provider) {
                        ForEach(group.models, id: \.name) { model in
                            Button { choice.wrappedValue = .named(model.name) } label: {
                                Text(verbatim: String(model.name.dropFirst(group.provider.count + 1)))
                            }
                        }
                    }
                }
                Divider()
                Button("Other…") { choice.wrappedValue = .other }
            } label: {
                switch choice.wrappedValue {
                case .agentDefault: Text("\(cli.name)'s default model")
                case .unset: Text("Choose a model")
                case .named(let model): Text(verbatim: model)
                case .other: Text("Other…")
                }
            }
            .fixedSize()
        }
    }

    /// The model menu's choice: the agent's default for no model, *Other…* for a model the menu
    /// does not list, which is then typed.
    private func modelChoice(_ cli: AgentCLI) -> Binding<ModelChoice> {
        Binding {
            let model = profile.model.trimmingCharacters(in: .whitespaces)
            if typesModel { return .other }
            if model.isEmpty { return cli.hasDefaultModel ? .agentDefault : .unset }
            return agentModels?.contains { $0.name == model } == true ? .named(model) : .other
        } set: { choice in
            typesModel = choice == .other
            switch choice {
            case .agentDefault, .unset: profile.model = ""
            case .named(let model): profile.model = model
            case .other: break
            }
        }
    }

    /// Takku Credit has nothing to configure but the key: address, model and context are the gateway's.
    @ViewBuilder private var creditRows: some View {
        Text("Prepaid credit for Summaries, sold by Takku's author: no account to create, only the key that arrives by email. The Transcript and your notes go to api.takku.app and on to a model hosted in the EU; nothing of the Meeting is kept.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        LabeledContent("Credit") {
            HStack {
                if let credit {
                    creditAmount(credit)
                } else if storedKeySuffix == nil {
                    Text("Buy a pack, then paste the key from the email below.").foregroundStyle(.secondary)
                }
                if isReadingCredit { ProgressView().controlSize(.small) }
                Spacer()
                if storedKeySuffix == nil {
                    Button("Buy credit…") { NSWorkspace.shared.open(TakkuCredit.buyURL) }
                } else {
                    IconButton(title: "Refresh", systemImage: "arrow.clockwise") { Task { await readCredit() } }
                        .disabled(isReadingCredit)
                    if let credit, let recommended = credit.recommendedPack {
                        // The button buys the recommended pack; its menu has them all.
                        Menu("Add credit…") {
                            ForEach(credit.packs, id: \.url) { pack in
                                Button(packTitle(pack)) { NSWorkspace.shared.open(pack.url) }
                            }
                        } primaryAction: {
                            NSWorkspace.shared.open(recommended.url)
                        }
                        .fixedSize()
                    }
                }
            }
        }
        if let creditProblem {
            Text(creditProblem).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    /// Never a negative amount: the last Summary may take the balance a little below zero, which
    /// means the same as zero. Under a cent it says so instead of showing "0,00 €".
    @ViewBuilder private func creditAmount(_ credit: TakkuCredit.Balance) -> some View {
        if credit.micros <= 0 {
            Text("Used up").foregroundStyle(.red)
        } else if credit.micros < 10_000 {
            Text("< \(Decimal(string: "0.01")!, format: .currency(code: "EUR"))").foregroundStyle(.red)
        } else {
            Text(credit.euros, format: .currency(code: "EUR"))
        }
    }

    private func packTitle(_ pack: TakkuCredit.Pack) -> String {
        let price = pack.priceEuros.formatted(.currency(code: "EUR").precision(.fractionLength(0)))
        return pack.isRecommended ? String(localized: "\(price) pack · Recommended") : String(localized: "\(price) pack")
    }

    @ViewBuilder private var providerRows: some View {
        LabeledContent("Name") {
            PasteableTextField(placeholder: String(localized: "e.g. Mistral EU"), text: $profile.name)
        }
        LabeledContent("Base URL") {
            PasteableTextField(placeholder: String(localized: "e.g. https://api.mistral.ai/v1"), text: $profile.baseURL)
        }
        LabeledContent("Model") {
            PasteableTextField(placeholder: String(localized: "e.g. mistral-medium-latest"), text: $profile.model)
        }
        TextField("Max context (tokens)", value: $profile.maxContextTokens, format: .number)
        Picker("Reasoning", selection: $profile.reasoning) {
            Text("Model default").tag(ProviderProfile.ReasoningEffort?.none)
            ForEach(ProviderProfile.ReasoningEffort.allCases, id: \.self) { effort in
                Text(effort.displayName).tag(ProviderProfile.ReasoningEffort?.some(effort))
            }
        }
        LabeledContent("Extra parameters") {
            PasteableTextField(
                placeholder: String(localized: "JSON, e.g. {\"reasoning_effort\": \"xhigh\"}"),
                text: $extraParameters, isCode: true
            )
        }
        .onChange(of: extraParameters) { saveExtraParameters() }
        if let extraParametersProblem {
            Text(extraParametersProblem).foregroundStyle(.red)
        } else {
            Text("Added to every request as written; each key replaces what Takku sends for it. For what a model needs beyond the Reasoning menu: see the provider's documentation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // An exception: almost every provider takes Chat Completions.
        Toggle("Use the Responses API", isOn: Binding(
            get: { profile.api == .responses },
            set: { profile.api = $0 ? .responses : .chatCompletions; saveExtraParameters() }
        ))
        .controlSize(.small)
        Text("Only for providers and models that need it, such as some OpenAI models.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Saved only when valid: otherwise the field shows the problem and the Profile keeps the
    /// last valid parameters.
    private func saveExtraParameters() {
        do {
            profile.extraParameters = try ExtraParameters.parse(extraParameters, api: profile.api).isEmpty ? nil : extraParameters
            extraParametersProblem = nil
        } catch {
            extraParametersProblem = error.localizedDescription
        }
    }

    private func saveKey() {
        _ = saveKeyIfNeeded(announce: true)
    }

    /// Saves a key typed in the field before testing or activating the Profile, so pasting a key
    /// and pressing *Test connection* or *Use for Summaries* works without pressing *Save key* first.
    @discardableResult
    private func saveKeyIfNeeded(announce: Bool = false) -> Bool {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        do {
            try Keychain.setAPIKey(trimmed, for: profile.id)
            apiKey = ""
            refreshStoredKey()
            if announce { status = String(localized: "Key saved in the Keychain.") }
            Task { await readCredit() }
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func refreshStoredKey() {
        storedKeySuffix = Keychain.apiKey(for: profile.id).map { String($0.suffix(4)) }
    }

    /// The balance of the key in the Keychain, for Takku Credit; nothing for other Profiles or without a key.
    private func readCredit() async {
        guard profile.isTakkuCredit, let key = Keychain.apiKey(for: profile.id), !isReadingCredit else { return }
        isReadingCredit = true
        defer { isReadingCredit = false }
        do {
            credit = try await TakkuCredit.balance(apiKey: key, transport: TakkuCredit.transport)
            creditProblem = nil
        } catch {
            credit = nil
            creditProblem = String(localized: "Could not read the credit: \(error.localizedDescription)")
        }
    }

    /// The agent's problem, read again when the user comes back from Terminal, and its models when
    /// none are read yet or the problem changed (a list is a run of the CLI: Copilot's takes seconds).
    private func checkAgentCLI() async {
        guard let cli = profile.agentCLI else { return }
        // Looked up again: the user may have installed it elsewhere meanwhile.
        let executable = await cli.executable(refresh: true)
        let runner = AgentCLI.Runner(cli)
        let problem = await runner.unavailability()
        let changed = problem?.localizedDescription != cliProblem
        cliProblem = problem?.localizedDescription
        let version = executable == nil ? nil : await runner.version()
        cliInstall = executable.map { (path: ($0.path as NSString).abbreviatingWithTildeInPath, version: version) }
        if problem != .notInstalled(cli) && (agentModels == nil || changed) { agentModels = await runner.models() }
    }

    private func test() async {
        guard saveKeyIfNeeded() else { return }
        isTesting = true
        defer { isTesting = false }
        do {
            let reply = try await ChatClient(profile: profile).complete([
                ChatMessage(role: .user, content: "Reply with the word OK only."),
            ])
            status = String(localized: "It works. Reply: \(String(reply.prefix(40)))")
        } catch {
            status = error.localizedDescription
        }
    }
}
