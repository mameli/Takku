import AppKit
import SwiftUI
import TakkuCore

/// Who writes the Summary: a model on this Mac, or an external one, which gets only the text.
/// Takku Credit is done here, start to end: a pack bought from the gateway's list, the key from
/// the email pasted, checked and made the Profile for Summaries, without going through Settings.
/// The packs show only once asked for: a free app does not open with a price list.
struct SummarySetup: View {
    /// How much of Takku Credit is open.
    enum CreditStep {
        /// What it is and what it costs, in words.
        case closed
        /// The packs, then the key.
        case buying
        /// Only the key, for one bought on takku.app or before.
        case pastingKey
    }

    /// Shown in place of the gateway's answer by `-renderWelcome`, which runs no task.
    private let previewPacks: [TakkuCredit.Pack]?

    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppSettings.activeProviderProfileKey) private var activeProfileID = ""
    /// `nil` while asking the gateway; empty when it gave none (offline, an older gateway): then
    /// one button opens takku.app/credit.
    @State private var packs: [TakkuCredit.Pack]?
    @State private var key = ""
    @State private var isActivating = false
    @State private var problem: String?
    @State private var balance: TakkuCredit.Balance?
    @State private var step: CreditStep

    init(previewPacks: [TakkuCredit.Pack]? = nil, previewStep: CreditStep = .closed) {
        self.previewPacks = previewPacks
        _packs = State(initialValue: previewPacks)
        _step = State(initialValue: previewStep)
    }

    /// What the gateway says a Summary costs, about: as on takku.app/credit (5 € ≈ 400 meetings).
    private static let meetingsPerEuro: Decimal = 80

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                onThisMac.frame(width: 190)
                external
            }
            .fixedSize(horizontal: false, vertical: true)
            Text("Without one, Takku writes only the Transcript.")
                .font(Paper.serif(12.5)).foregroundStyle(Paper.graphite)
        }
        .task { await load() }
    }

    private var active: ProviderProfile? {
        _ = activeProfileID
        return AppSettings.activeProviderProfile
    }

    // MARK: On this Mac

    private var onThisMac: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HandStatus(isDone: active?.runsOnThisMac == true ? true : nil)
                Text("On this Mac").font(Paper.hand(18, bold: true)).foregroundStyle(Paper.ink)
            }
            Text("Ollama or LM Studio, with a model on your Mac. Nothing leaves the Mac, but it takes a powerful Mac, and the Summaries are less precise.")
                .font(Paper.serif(12.5)).foregroundStyle(Paper.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Set up in Settings…") {
                openProfiles(AppSettings.summaryProfiles.first { $0.runsOnThisMac }?.id)
            }
            .buttonStyle(PaperButtonStyle(isPrimary: false))
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .card(800)
    }

    // MARK: External

    private var external: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("An external AI model").font(Paper.hand(18, bold: true)).foregroundStyle(Paper.ink)
            Text("It gets only the text of the Transcript and your notes, never the audio.")
                .font(Paper.serif(12.5)).foregroundStyle(Paper.text)
                .fixedSize(horizontal: false, vertical: true)
            takkuCredit
            HStack(spacing: 4) {
                Text("Mistral, OpenRouter or another provider?").font(Paper.serif(12)).foregroundStyle(Paper.graphite)
                Button("Settings…") { openProfiles(nil) }
                    .buttonStyle(PaperButtonStyle(isPrimary: false))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .card(810)
    }

    private var takkuCredit: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if active?.isTakkuCredit == true { HandStatus(isDone: true) }
                Text(verbatim: "Takku Credit").font(Paper.hand(17, bold: true)).foregroundStyle(Paper.ink)
            }
            Text("A model hosted in the EU, and nothing is kept. No subscription, no account, and the credit never expires.")
                .font(Paper.serif(12)).foregroundStyle(Paper.text)
                .fixedSize(horizontal: false, vertical: true)
            if active?.isTakkuCredit == true {
                activeCredit
            } else {
                switch step {
                case .closed:
                    Text("You pay only for the Summaries Takku writes. Recording and transcription stay free, on your Mac.")
                        .font(Paper.serif(12)).foregroundStyle(Paper.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button("Use Takku Credit…") { step = .buying }
                            .buttonStyle(PaperButtonStyle())
                        Button("I already have a key") { step = .pastingKey }
                            .buttonStyle(PaperButtonStyle(isPrimary: false))
                    }
                    .padding(.top, 2)
                case .buying:
                    stepLabel(1, "Buy a pack: the key arrives by email.")
                    packButtons
                    stepLabel(2, "Paste the key from the email.")
                    keyField
                case .pastingKey:
                    stepLabel(1, "Paste the key from the email.")
                    keyField
                }
            }
            if let problem {
                Text(problem).font(Paper.serif(12)).foregroundStyle(Paper.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background {
            ZStack {
                box(830, radius: 5).fill(Paper.yellow.opacity(0.12))
                box(831, radius: 5).stroke(Paper.yellow, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func stepLabel(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: "\(number)")
                .font(Paper.hand(13, bold: true)).foregroundStyle(Paper.ink)
                .frame(width: 18, height: 18)
                .background(Sketch(Circle(), seed: 840 &+ UInt64(number)).stroke(Paper.ink, style: Paper.stroke))
            Text(text).font(Paper.serif(12.5)).foregroundStyle(Paper.text)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var packButtons: some View {
        if let packs, !packs.isEmpty {
            HStack(spacing: 8) {
                ForEach(packs, id: \.url) { pack in
                    Button { NSWorkspace.shared.open(pack.url) } label: { packLabel(pack) }
                        .buttonStyle(.plain)
                }
            }
        } else if packs != nil {
            Button("Buy credit…") { NSWorkspace.shared.open(TakkuCredit.buyURL) }
                .buttonStyle(PaperButtonStyle())
        } else {
            ProgressView().controlSize(.small).frame(height: 44)
        }
    }

    private func packLabel(_ pack: TakkuCredit.Pack) -> some View {
        let meetings = NSDecimalNumber(decimal: pack.priceEuros * Self.meetingsPerEuro).intValue
        return VStack(spacing: 0) {
            Text(pack.priceEuros, format: .currency(code: "EUR").precision(.fractionLength(0)))
                .font(Paper.hand(17, bold: true))
            Text("about \(meetings) meetings").font(Paper.serif(11))
        }
        .foregroundStyle(pack.isRecommended ? Color(red: 0.11, green: 0.13, blue: 0.19) : Paper.ink)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background {
            if pack.isRecommended {
                ZStack {
                    box(850, radius: 4).fill(Color(red: 0.94, green: 0.71, blue: 0.24))
                    box(853, radius: 4).stroke(Color(red: 0.11, green: 0.13, blue: 0.19), style: Paper.stroke)
                }
            } else {
                ZStack {
                    box(851, radius: 4).fill(Paper.card)
                    box(852, radius: 4).stroke(Paper.ink, style: Paper.stroke)
                }
            }
        }
        .contentShape(Rectangle())
        .help(pack.isRecommended ? String(localized: "Recommended") : "")
    }

    private var keyField: some View {
        HStack(spacing: 10) {
            TextField(text: $key, prompt: Text(verbatim: "tk_…")) { Text("Key") }
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Paper.ink)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(box(860, radius: 4).stroke(Paper.graphite, style: Paper.stroke))
                .onSubmit { Task { await activate() } }
            if isActivating {
                ProgressView().controlSize(.small)
            } else {
                Button("Activate") { Task { await activate() } }
                    .buttonStyle(PaperButtonStyle())
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var activeCredit: some View {
        HStack(spacing: 10) {
            Group {
                if let balance {
                    Text("Used for Summaries · credit \(balance.euros.formatted(.currency(code: "EUR")))")
                } else {
                    Text("Used for Summaries")
                }
            }
            .font(Paper.serif(12.5)).foregroundStyle(Paper.green)
            Spacer()
            if let pack = balance?.recommendedPack {
                Button("Add credit…") { NSWorkspace.shared.open(pack.url) }
                    .buttonStyle(PaperButtonStyle(isPrimary: false))
            }
        }
    }

    // MARK: Actions

    private func load() async {
        if let previewPacks {
            packs = previewPacks
            return
        }
        packs = (try? await TakkuCredit.packs(transport: TakkuCredit.transport)) ?? []
        if let profile = active, profile.isTakkuCredit, let key = Keychain.apiKey(for: profile.id) {
            balance = try? await TakkuCredit.balance(apiKey: key, transport: TakkuCredit.transport)
        }
    }

    /// Checks the key with the gateway, then makes Takku Credit the Profile for Summaries, with the
    /// key in the Keychain. An existing Takku Credit Profile gets the new key.
    private func activate() async {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !isActivating else { return }
        guard key.hasPrefix("tk_") else {
            problem = String(localized: "This is not a Takku Credit key: the one in the email starts with tk_.")
            return
        }
        isActivating = true
        defer { isActivating = false }
        do {
            balance = try await TakkuCredit.balance(apiKey: key, transport: TakkuCredit.transport)
            var profiles = AppSettings.summaryProfiles
            let profile = profiles.first(where: \.isTakkuCredit) ?? {
                let credit = ProviderProfile.takkuCredit()
                profiles.insert(credit, at: 0)
                return credit
            }()
            AppSettings.summaryProfiles = profiles
            try Keychain.setAPIKey(key, for: profile.id)
            activeProfileID = profile.id.uuidString
            self.key = ""
            problem = nil
        } catch {
            problem = String(localized: "The key was not accepted: \(error.localizedDescription)")
        }
    }

    private func openProfiles(_ profile: UUID?) {
        SettingsRequest.shared.selectsProfile = profile
        SettingsRequest.shared.showsProfiles = true
        NSApplication.shared.activate()
        openSettings()
    }
}
