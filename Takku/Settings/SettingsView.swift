import AppKit
import TakkuCore
import SwiftUI

/// Where the Settings window goes when it opens or comes to the front: the welcome window's
/// *Choose a Profile in Settings…* sends it to the Summary Profiles.
@MainActor @Observable
final class SettingsRequest {
    static let shared = SettingsRequest()
    var showsProfiles = false
    /// Set when the Summary tab is shown on request: it opens a new Profile if there are none yet.
    var opensNewProfile = false
}

/// The tabs of the Settings window, in the toolbar as in the Mac's own apps.
enum SettingsTab: Hashable {
    case general, notes, transcription, summary, recordings
}

/// Settings window, one tab per subject: General (start at login, calendar, call suggestions,
/// updates, keyboard shortcuts), Notes (Vault, Templates, Vocabulary), Transcription (Meeting languages and models),
/// Summary (Provider Profiles) and Recordings (audio and Summary log kept on this Mac).
struct SettingsView: View {
    let models: TranscriptionModels
    @State private var tab = SettingsTab.general
    private let request = SettingsRequest.shared

    var body: some View {
        TabView(selection: $tab) {
            GeneralTab()
                .fittingContent()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            NotesTab()
                .fittingContent()
                .tabItem { Label("Notes", systemImage: "note.text") }
                .tag(SettingsTab.notes)
            Form {
                TranscriptionSection(models: models)
                VoicesSection()
            }
            .formStyle(.grouped)
            .fittingContent()
            .tabItem { Label("Transcription", systemImage: "waveform") }
            .tag(SettingsTab.transcription)
            // The Profile editor is long: this tab keeps a fixed height and scrolls.
            SummaryTab()
                .frame(width: Self.width, height: Self.maxHeight)
                .tabItem { Label("Summary", systemImage: "sparkles") }
                .tag(SettingsTab.summary)
            Form { RecordingsSection() }
                .formStyle(.grouped)
                .fittingContent()
                .tabItem { Label("Recordings", systemImage: "internaldrive") }
                .tag(SettingsTab.recordings)
        }
        .onAppear { showProfilesIfRequested() }
        .onChange(of: request.showsProfiles) { showProfilesIfRequested() }
    }

    static let width: CGFloat = 560
    static let maxHeight: CGFloat = 640

    /// The Summary tab, with a new Profile open in the editor if there are none yet (see `SummaryTab`).
    private func showProfilesIfRequested() {
        guard request.showsProfiles else { return }
        request.showsProfiles = false
        request.opensNewProfile = true
        tab = .summary
    }
}

private extension View {
    /// A tab as tall as what it shows: the window grows and shrinks with the tab, with no empty
    /// space under a short one. Up to the Summary tab's height: a longer one (many voices
    /// remembered) scrolls instead of growing past the screen.
    func fittingContent() -> some View {
        modifier(FittingContent())
    }
}

/// Only a tab cut at the maximum height scrolls and shows a scroll bar: a short one stays still,
/// even with *Show scroll bars: Always*.
private struct FittingContent: ViewModifier {
    @State private var overflows = false

    func body(content: Content) -> some View {
        content
            .frame(width: SettingsView.width)
            .frame(maxHeight: SettingsView.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollDisabled(!overflows)
            .scrollIndicators(overflows ? .automatic : .never)
            // A point of margin: the ideal height and the content can differ by a rounding.
            .onScrollGeometryChange(for: Bool.self) {
                $0.contentSize.height > $0.containerSize.height + 1
            } action: { _, overflows in
                self.overflows = overflows
            }
    }
}

private struct GeneralTab: View {
    var body: some View {
        Form {
            Section {
                LaunchAtLoginToggle()
                CalendarToggle()
                SuggestCallsToggle()
                UpdatesToggle()
            } header: {
                AppIdentity().frame(maxWidth: .infinity).padding(.bottom, 8)
            }

            ShortcutsSection()

            // At the bottom, in grey: seen by those who look, not first thing.
            Section {
            } footer: {
                Text(Self.supportNote)
                    .foregroundStyle(.secondary)
                    .tint(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }

    /// The link is grey like the text around it, so it is underlined to show it is one.
    private static var supportNote: AttributedString {
        var note = AttributedString(localized: "Takku is free. If it is useful to you, [buy me a coffee](https://buymeacoffee.com/mameli.dev).")
        for run in note.runs where run.link != nil {
            note[run.range].underlineStyle = .single
        }
        return note
    }
}

/// Where the notes go and what shapes them: the Vault and its Editor, the Templates, the Vocabulary.
private struct NotesTab: View {
    @State private var vaultPath = AppSettings.vaultPath ?? ""
    @State private var defaultTemplate = AppSettings.defaultTemplate

    var body: some View {
        Form {
            Section("Obsidian Vault") {
                LabeledContent("Folder") {
                    HStack {
                        Text(vaultPath.isEmpty ? String(localized: "None") : vaultPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(vaultPath.isEmpty ? .secondary : .primary)
                        Button("Choose…") {
                            if let path = Vault.choose() { vaultPath = path }
                        }
                    }
                }
                EditorRow()
                OpenNoteAtStartToggle()
            }
            TemplatesSection(defaultTemplate: $defaultTemplate)
            VocabularySection()
        }
        .formStyle(.grouped)
    }
}

/// The Summary Profiles: the list, adding and deleting them, and the editor of the selected one.
private struct SummaryTab: View {
    @State private var profiles = AppSettings.summaryProfiles
    @AppStorage(AppSettings.activeProviderProfileKey) private var activeProfileID = ""
    @State private var selectedProfileID = AppSettings.activeProviderProfile?.id ?? AppSettings.summaryProfiles.first?.id
    @State private var confirmsCreditDeletion = false
    private let request = SettingsRequest.shared

    var body: some View {
        Form {
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
                addAndDelete
            } header: {
                Text("Summary Profiles")
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
        }
        .formStyle(.grouped)
        .onAppear { addProfileIfRequested() }
        .onChange(of: request.opensNewProfile) { addProfileIfRequested() }
        .onChange(of: profiles) { AppSettings.summaryProfiles = profiles }
        .confirmationDialog("Delete the Takku Credit Profile?", isPresented: $confirmsCreditDeletion) {
            Button("Delete", role: .destructive, action: deleteSelectedProfile)
        } message: {
            Text("The key leaves this Mac, the credit stays with it: keep the email with the key to paste it again.")
        }
    }

    /// + and − under the list, as in the Mac's own lists. The + offers Takku Credit to those who
    /// had Profiles before it existed, or deleted it: ready-made ones come only once.
    private var addAndDelete: some View {
        HStack(spacing: 12) {
            if profiles.contains(where: \.isTakkuCredit) {
                IconButton(title: "Add Profile", systemImage: "plus", action: addProfile)
            } else {
                Menu {
                    Button("New Profile", action: addProfile)
                    Button("Takku Credit", action: addTakkuCredit)
                } label: {
                    RowIcon(systemImage: "plus").accessibilityLabel(Text("Add Profile"))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Add Profile"))
            }
            IconButton(title: "Delete Profile", systemImage: "minus", action: askToDeleteSelectedProfile)
                .disabled(selectedProfileID == nil)
            Spacer()
        }
    }

    /// From the welcome window: with no Profiles yet, a new one is open in the editor.
    private func addProfileIfRequested() {
        guard request.opensNewProfile else { return }
        request.opensNewProfile = false
        if profiles.isEmpty { addProfile() }
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
