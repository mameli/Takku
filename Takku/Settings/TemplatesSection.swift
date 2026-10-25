import AppKit
import TakkuCore
import SwiftUI

/// The Templates in `~/.takku/templates`: created here and written in the user's editor.
struct TemplatesSection: View {
    @Binding var defaultTemplate: String
    @State private var names: [String] = []
    @State private var newName = ""
    /// The New Template row shows its name field.
    @State private var isNaming = false
    @State private var status: String?
    @State private var pendingDeletion: String?
    /// Read when the section appears: apps come and go.
    @State private var editors = TextEditors.none

    var body: some View {
        Section {
            ForEach(names, id: \.self) { name in
                HStack {
                    Text(name)
                    if name == defaultTemplate {
                        Text("Default").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                    MoreMenu {
                        EditWithMenu(title: "Edit With", editors: editors) { app in
                            TextEditors.open(TakkuFolder.templateURL(name), with: app)
                        }
                        if name != defaultTemplate {
                            Button("Use as Default") {
                                defaultTemplate = name
                                AppSettings.defaultTemplate = name
                            }
                        }
                        // Notes cannot go: Takku would create it again as the fallback Template.
                        if name != Template.defaultName {
                            Divider()
                            Button("Move to Trash…", role: .destructive) { pendingDeletion = name }
                        }
                    }
                }
            }

            if isNaming {
                LabeledContent("New Template") {
                    HStack {
                        PasteableTextField(placeholder: String(localized: "e.g. Weekly 1:1"), text: $newName, onSubmit: create)
                        Button("Create", action: create)
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Cancel") {
                            isNaming = false
                            newName = ""
                        }
                    }
                }
            } else {
                Button {
                    isNaming = true
                } label: {
                    Label("New Template…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            if let status {
                Text(status).foregroundStyle(.secondary)
            }
        } header: {
            Text("Templates")
        } footer: {
            Text("The default Template is used for new Meetings; ⋯ changes it. A new Template starts from Notes: change instructions and sections with Edit With. They live in ~/.takku/templates/.")
                .foregroundStyle(.secondary)
        }
        .onAppear {
            editors = .markdown()
            reload()
        }
        // Back from the editor or Finder, where Templates can be added or renamed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .confirmationDialog(
            String(localized: "Move the Template \"\(pendingDeletion ?? "")\" to the Trash?"),
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let name = pendingDeletion { delete(name) }
            }
        } message: {
            Text("Meetings that used it switch to the Notes Template.")
        }
    }

    private func reload() {
        names = TakkuFolder.templateNames()
    }

    private func create() {
        do {
            guard !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            _ = try TakkuFolder.createTemplate(named: newName)
            newName = ""
            isNaming = false
            reload()
            // The new row, with its Edit With, is enough.
            status = nil
        } catch {
            status = error.localizedDescription
        }
    }

    private func delete(_ name: String) {
        do {
            try TakkuFolder.trashTemplate(named: name)
            try? TakkuFolder.ensureDefaultTemplate()
            defaultTemplate = AppSettings.defaultTemplate
            reload()
            // The row disappearing is enough: no message, and none left over from before.
            status = nil
        } catch {
            status = error.localizedDescription
        }
        pendingDeletion = nil
    }
}
