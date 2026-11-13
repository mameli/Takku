import TakkuCore
import SwiftUI

/// The Meeting languages and the transcription models: download, choose the one in use, delete
/// the others. The four offered first are listed here, with the model in use; the others are in a
/// sheet, so a long list does not stretch the Transcription tab.
struct TranscriptionSection: View {
    let models: TranscriptionModels
    @AppStorage(AppSettings.transcriptionModelKey) private var selectedID = TranscriptionModel.default.id
    @State private var error: String?
    @State private var languages = AppSettings.meetingLanguages
    @State private var showsOtherModels = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent("Meeting languages") {
                    MeetingLanguagesMenu(languages: $languages).fixedSize()
                }
                Text(MeetingLanguagesMenu.explanation(languages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(TranscriptionModel.all.filter { $0.isFeatured || $0.id == selectedID }) { model in
                TranscriptionModelRow(model: model, models: models, selectedID: $selectedID, languages: languages, error: $error)
            }
            // The whole row opens the sheet, as a row with a chevron does in System Settings.
            Button { showsOtherModels = true } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Other models")
                        Text("Lighter, larger or English only, for other needs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } footer: {
            Text("Models run on this Mac and are downloaded once from Hugging Face; no audio or text is sent. The selected model is used for new meetings and when reprocessing a recording.")
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsOtherModels) {
            OtherModelsSheet(models: models, selectedID: $selectedID, languages: languages)
        }
    }
}

/// Every model outside the four offered first, with the same row as in Settings.
private struct OtherModelsSheet: View {
    let models: TranscriptionModels
    @Binding var selectedID: String
    let languages: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Form {
                Section {
                    ForEach(TranscriptionModel.all.filter { !$0.isFeatured }) { model in
                        TranscriptionModelRow(model: model, models: models, selectedID: $selectedID, languages: languages, error: $error)
                    }
                    if let error {
                        Text(error).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                } header: {
                    Text("Other models")
                } footer: {
                    Text("Parakeet Ultra and Whisper Large v3 Turbo suit most meetings; these are for other needs.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 560)
    }
}

/// A model: name, note and size, then its download, its percentage or its ⋯ menu (*Use*, *Delete*).
private struct TranscriptionModelRow: View {
    let model: TranscriptionModel
    let models: TranscriptionModels
    @Binding var selectedID: String
    let languages: [String]
    @Binding var error: String?

    var body: some View {
        // Read through `selectedID`, so the rows follow a change made in the menu.
        let isSelected = model.id == (TranscriptionModel.all.first { $0.id == selectedID } ?? .default).id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(verbatim: model.name)
                    if isSelected {
                        Text("In use").font(.caption).foregroundStyle(.green)
                    }
                }
                HStack(spacing: 4) {
                    Text(model.note)
                    Text(verbatim: "·")
                    Text((Int64(model.downloadMB) * 1_000_000).formatted(.byteCount(style: .file)))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if isSelected && model.isEnglishOnly && languages != ["en"] {
                    Text("Meetings in another language come out wrong: tick only English in Meeting languages, or use another model.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let percent = models.progress[model.id] {
                if percent < 100 {
                    ProgressView(value: Double(percent), total: 100).frame(width: 80)
                    Text(verbatim: "\(percent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Preparing…").foregroundStyle(.secondary)
                }
            } else if models.isDownloaded(model) {
                // The model in use is not deleted: the next Meeting would download it again.
                if !isSelected {
                    MoreMenu {
                        Button("Use") { selectedID = model.id }
                        Divider()
                        Button("Delete", role: .destructive) { delete() }
                    }
                }
            } else {
                IconButton(title: "Download", systemImage: "arrow.down.circle") { download() }
            }
        }
    }

    private func download() {
        error = nil
        Task {
            do {
                try await models.download(model)
            } catch {
                self.error = String(localized: "Download of \(model.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func delete() {
        do {
            try models.delete(model)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// The Meeting languages ticked, as a menu of the offered ones: in Settings and in the welcome window.
struct MeetingLanguagesMenu: View {
    @Binding var languages: [String]

    var body: some View {
        Menu(languages.map(MeetingLanguages.name).formatted(.list(type: .and))) {
            ForEach(MeetingLanguages.offered, id: \.self) { code in
                Toggle(MeetingLanguages.name(code), isOn: isTicked(code))
            }
        }
    }

    static func explanation(_ languages: [String]) -> String {
        languages.count == 1
            ? String(localized: "Every meeting is transcribed in this language.")
            : String(localized: "Takku detects which of these languages each meeting is in.")
    }

    /// At least one language stays ticked.
    private func isTicked(_ code: String) -> Binding<Bool> {
        Binding {
            languages.contains(code)
        } set: { isOn in
            var ticked = languages.filter { $0 != code }
            if isOn { ticked.append(code) }
            guard !ticked.isEmpty else { return }
            AppSettings.meetingLanguages = ticked
            languages = AppSettings.meetingLanguages
        }
    }
}
