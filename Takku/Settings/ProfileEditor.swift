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

    var body: some View {
        Section {
            if profile.isTakkuCredit {
                creditRows
            } else {
                providerRows
            }

            // The only place where the key is entered. It is saved only on Return or with the
            // button, never while typing: a stray keystroke must not replace a working key.
            LabeledContent("API key") {
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
            }

            HStack {
                Button("Test connection") { Task { await test() } }
                    .disabled(isTesting || profile.baseURL.isEmpty || profile.model.isEmpty || extraParametersProblem != nil)
                if isTesting { ProgressView().controlSize(.small) }
                Spacer()
                if isActive {
                    Text("Used for Summaries").foregroundStyle(.green)
                } else {
                    Button("Use for Summaries", action: activate)
                }
            }
            if let status {
                Text(status).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } header: {
            Text("Profile: \(profile.displayName)")
        } footer: {
            Text("Changes are saved as you type. The key goes to the Keychain when you press Return or Save key.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            refreshStoredKey()
            extraParameters = profile.extraParameters ?? ""
            Task { await readCredit() }
        }
        // Back from the browser after paying: the new balance without pressing anything.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await readCredit() }
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
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try Keychain.setAPIKey(apiKey, for: profile.id)
            apiKey = ""
            refreshStoredKey()
            status = String(localized: "Key saved in the Keychain.")
            Task { await readCredit() }
        } catch {
            status = error.localizedDescription
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
            credit = try await TakkuCredit.balance(apiKey: key) { request in
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                return (data, http)
            }
            creditProblem = nil
        } catch {
            credit = nil
            creditProblem = String(localized: "Could not read the credit: \(error.localizedDescription)")
        }
    }

    private func test() async {
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
