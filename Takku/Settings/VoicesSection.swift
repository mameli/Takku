import SwiftUI
import TakkuCore

/// Voice recognition: on or off, and how many voices are remembered. The voices themselves are
/// in a sheet, so a long list does not stretch the Transcription tab.
struct VoicesSection: View {
    @AppStorage(AppSettings.recognizeVoicesKey) private var recognizeVoices = false
    @State private var library = VoiceLibrary()
    @State private var isConfirmingOn = false
    @State private var isManaging = false

    var body: some View {
        Section {
            Toggle("Recognise voices", isOn: Binding {
                recognizeVoices
            } set: { isOn in
                // Turning it on asks first: it means keeping other people's biometric data.
                if isOn { isConfirmingOn = true } else { recognizeVoices = false }
            })
            if !library.voices.isEmpty {
                LabeledContent("Remembered voices") {
                    HStack {
                        Text(verbatim: "\(library.voices.count)")
                        Button("Manage…") { isManaging = true }
                    }
                }
            }
        } footer: {
            Text("When you name the Speakers, Takku remembers their voices on this Mac and suggests the names in the next Meetings, while the audio is kept. A voice is biometric data: keep it only for people who agreed. Turning it off keeps the voices already remembered until you forget them.")
                .foregroundStyle(.secondary)
        }
        .onAppear { library = VoiceStorage.load() }
        .confirmationDialog(String(localized: "Recognise voices?"), isPresented: $isConfirmingOn) {
            Button("Recognise voices") { recognizeVoices = true }
        } message: {
            Text("Takku will keep the voices of the Speakers you name, on this Mac only. Under the GDPR a voice is biometric data: you need the consent of the people you name.")
        }
        .sheet(isPresented: $isManaging) {
            VoicesSheet(library: $library)
        }
    }
}

/// The remembered voices, alphabetical, with a search field: forget the selected ones (⌫ or
/// the context menu too) or all of them.
private struct VoicesSheet: View {
    @Binding var library: VoiceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: Set<String> = []
    @State private var isConfirmingDeletion = false
    @State private var error: String?

    private var shown: [VoiceLibrary.Voice] {
        let search = search.trimmingCharacters(in: .whitespaces)
        guard !search.isEmpty else { return library.voices }
        return library.voices.filter { $0.name.localizedStandardContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remembered voices").font(.headline)
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
            List(shown, id: \.name, selection: $selection) { voice in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: voice.name)
                    Text(heard(voice))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contextMenu {
                    Button("Forget", role: .destructive) {
                        forget(selection.contains(voice.name) ? selection : [voice.name])
                    }
                }
            }
            .listStyle(.bordered)
            .alternatingRowBackgrounds()
            .onDeleteCommand { forget(selection) }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("Forget", role: .destructive) { forget(selection) }
                    .disabled(selection.isEmpty)
                Button("Forget all voices…", role: .destructive) { isConfirmingDeletion = true }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 460)
        .confirmationDialog(String(localized: "Forget all voices?"), isPresented: $isConfirmingDeletion) {
            Button("Forget all voices", role: .destructive) {
                do {
                    try VoiceStorage.deleteAll()
                    error = nil
                } catch {
                    self.error = String(localized: "Voices not forgotten: \(error.localizedDescription)")
                }
                library = VoiceStorage.load()
                selection = []
                if library.voices.isEmpty { dismiss() }
            }
        } message: {
            Text("It cannot be undone. Names already in the notes are not touched.")
        }
    }

    private func heard(_ voice: VoiceLibrary.Voice) -> String {
        let meetings = voice.heard.count == 1
            ? String(localized: "Heard in 1 Meeting")
            : String(localized: "Heard in \(voice.heard.count) Meetings")
        guard let updated = voice.updated else { return meetings }
        return meetings + " · " + updated.formatted(date: .abbreviated, time: .omitted)
    }

    private func forget(_ names: Set<String>) {
        guard !names.isEmpty else { return }
        var updated = library
        for name in names { updated.forget(name) }
        do {
            try VoiceStorage.save(updated)
            library = updated
            selection.subtract(names)
            error = nil
            if library.voices.isEmpty { dismiss() }
        } catch {
            self.error = names.count == 1
                ? String(localized: "Voice not forgotten: \(error.localizedDescription)")
                : String(localized: "Voices not forgotten: \(error.localizedDescription)")
        }
    }
}
