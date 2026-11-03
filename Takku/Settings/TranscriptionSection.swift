import TakkuCore
import SwiftUI

/// The Meeting languages and the transcription models: download, choose the one in use, delete the others.
struct TranscriptionSection: View {
    let models: TranscriptionModels
    @AppStorage(AppSettings.transcriptionModelKey) private var selectedID = TranscriptionModel.default.id
    @State private var error: String?
    @State private var languages = AppSettings.meetingLanguages

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
            ForEach(TranscriptionModel.all) { model in
                row(model)
            }
            if let error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } footer: {
            Text("Models run on this Mac and are downloaded once from Hugging Face; no audio or text is sent. The selected model is used for new meetings and when reprocessing a recording.")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ model: TranscriptionModel) -> some View {
        // Read through `selectedID`, so the rows follow a change made in the menu.
        let isSelected = model.id == (TranscriptionModel.all.first { $0.id == selectedID } ?? .default).id
        return HStack {
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
                        Button("Delete", role: .destructive) { delete(model) }
                    }
                }
            } else {
                IconButton(title: "Download", systemImage: "arrow.down.circle") { download(model) }
            }
        }
    }

    private func download(_ model: TranscriptionModel) {
        error = nil
        Task {
            do {
                try await models.download(model)
            } catch {
                self.error = String(localized: "Download of \(model.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func delete(_ model: TranscriptionModel) {
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
