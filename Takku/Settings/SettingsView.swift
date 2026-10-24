import AppKit
import TakkuCore
import SwiftUI

/// Where the Settings window goes when it opens or comes to the front: the welcome window's
/// *Choose a Profile in Settings…* sends it to the Summary Profiles.
@MainActor @Observable
final class SettingsRequest {
    static let shared = SettingsRequest()
    var showsProfiles = false
}

/// Settings window: General (start at login, calendar, call suggestions, updates), Vault, Templates,
/// Vocabulary, Recordings, Meeting languages and transcription models, Provider Profiles for the Summary.
struct SettingsView: View {
    let models: TranscriptionModels
    @State private var vaultPath = AppSettings.vaultPath ?? ""
    @State private var profiles = AppSettings.summaryProfiles
    @AppStorage(AppSettings.activeProviderProfileKey) private var activeProfileID = ""
    @State private var selectedProfileID = AppSettings.activeProviderProfile?.id ?? AppSettings.summaryProfiles.first?.id
    @State private var defaultTemplate = AppSettings.defaultTemplate
    @State private var confirmsCreditDeletion = false
    private let request = SettingsRequest.shared

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    LaunchAtLoginToggle()
                    CalendarToggle()
                    SuggestCallsToggle()
                    UpdatesToggle()
                } header: {
                    // The header of the first Section, so the icon scrolls away with the rest.
                    VStack(alignment: .leading, spacing: 16) {
                        AppIdentity().frame(maxWidth: .infinity)
                        Text("General")
                    }
                }

                Section("Obsidian Vault") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(vaultPath.isEmpty ? String(localized: "None") : vaultPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                            Button("Choose…", action: chooseVault)
                        }
                    }
                    EditorRow()
                }

                TemplatesSection(defaultTemplate: $defaultTemplate)

                VocabularySection()

                RecordingsSection()

                TranscriptionSection(models: models)

                Section {
                    if profiles.isEmpty {
                        Text("No Profile yet. Add one to generate Summaries.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isActive: profile.id.uuidString == activeProfileID,
                            isSelected: profile.id == selectedProfileID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { selectedProfileID = profile.id }
                    }
                    HStack {
                        Button("Add Profile", action: addProfile)
                        // For those who had Profiles before it existed, or deleted it: ready-made ones come only once.
                        if !profiles.contains(where: \.isTakkuCredit) {
                            Button("Add Takku Credit", action: addTakkuCredit)
                        }
                        Spacer()
                        Button("Delete", role: .destructive, action: askToDeleteSelectedProfile)
                            .disabled(selectedProfileID == nil)
                    }
                    .confirmationDialog("Delete the Takku Credit Profile?", isPresented: $confirmsCreditDeletion) {
                        Button("Delete", role: .destructive, action: deleteSelectedProfile)
                    } message: {
                        Text("The key leaves this Mac, the credit stays with it: keep the email with the key to paste it again.")
                    }
                } header: {
                    Text("Summary Profiles").id(Self.profilesID)
                } footer: {
                    Text("Any server with an OpenAI-compatible API. For work meetings use only local Providers or Providers based and hosting data in the EU.")
                        .foregroundStyle(.secondary)
                }

                if let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
                    ProfileEditor(
                        profile: $profiles[index],
                        isActive: profiles[index].id.uuidString == activeProfileID,
                        activate: { activeProfileID = profiles[index].id.uuidString }
                    )
                    .id(profiles[index].id)
                }

                // At the bottom, in grey: seen by those who scroll this far, not first thing.
                Section {
                } footer: {
                    Text(Self.supportNote)
                        .foregroundStyle(.secondary)
                        .tint(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            .onAppear { showProfilesIfRequested(proxy) }
            .onChange(of: request.showsProfiles) { showProfilesIfRequested(proxy) }
        }
        .frame(width: 560)
        .frame(minHeight: 600)
        .onChange(of: profiles) { AppSettings.summaryProfiles = profiles }
    }

    private static let profilesID = "profiles"

    /// The link is grey like the text around it, so it is underlined to show it is one.
    private static var supportNote: AttributedString {
        var note = AttributedString(localized: "Takku is free. If it is useful to you, [buy me a coffee](https://buymeacoffee.com/mameli.dev).")
        for run in note.runs where run.link != nil {
            note[run.range].underlineStyle = .single
        }
        return note
    }

    /// Scrolls to the Summary Profiles, with a new one open in the editor if there are none yet.
    private func showProfilesIfRequested(_ proxy: ScrollViewProxy) {
        guard request.showsProfiles else { return }
        request.showsProfiles = false
        if profiles.isEmpty { addProfile() }
        // On the next turn: when the window has just opened the Form is not laid out yet.
        Task { @MainActor in
            withAnimation { proxy.scrollTo(Self.profilesID, anchor: .top) }
        }
    }

    private func chooseVault() {
        if let path = Vault.choose() { vaultPath = path }
    }

    private func addProfile() {
        let profile = ProviderProfile(
            name: "", baseURL: "", model: "", maxContextTokens: ProviderProfile.defaultMaxContextTokens
        )
        // Not made active: an empty Profile would make every Meeting fail until it is filled in.
        // The user activates it with "Use for Summaries" once it works.
        profiles.append(profile)
        selectedProfileID = profile.id
    }

    private func addTakkuCredit() {
        let profile = ProviderProfile.takkuCredit()
        profiles.insert(profile, at: 0)
        selectedProfileID = profile.id
    }

    /// The Takku Credit key is money: deleting it asks first.
    private func askToDeleteSelectedProfile() {
        if profiles.first(where: { $0.id == selectedProfileID })?.isTakkuCredit == true {
            confirmsCreditDeletion = true
        } else {
            deleteSelectedProfile()
        }
    }

    private func deleteSelectedProfile() {
        guard let id = selectedProfileID else { return }
        Keychain.deleteAPIKey(for: id)
        profiles.removeAll { $0.id == id }
        if activeProfileID == id.uuidString { activeProfileID = "" }
        selectedProfileID = profiles.first?.id
    }
}
