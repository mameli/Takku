import Foundation
import TakkuCore

/// `~/.takku`, the global configuration: the Templates (`templates/`) and the Vocabulary
/// (`vocabulary.md`). Plain Markdown files, the same whatever the Vault, edited with the
/// user's editor (*Edit With* in Settings). Also the user's Hook (`hooks/`), never created by Takku,
/// and the Summary log (`summary-log/`), which Takku writes and never reads.
enum TakkuFolder {
    static var root: URL {
        #if DEBUG
        // Automated tests: Templates, Vocabulary, Summary log and Hooks stay outside the real folder.
        if let path = UserDefaults.standard.string(forKey: "testTakkuFolder") {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #endif
        return URL.homeDirectory.appending(path: ".takku", directoryHint: .isDirectory)
    }
    static var templatesFolder: URL { root.appending(path: "templates", directoryHint: .isDirectory) }
    static var vocabularyURL: URL { root.appending(path: "vocabulary.md") }
    static var hooksFolder: URL { root.appending(path: "hooks", directoryHint: .isDirectory) }
    static var summaryLogFolder: URL { root.appending(path: "summary-log", directoryHint: .isDirectory) }

    // MARK: - Templates

    /// The available Templates, by file name (without `.md`), in alphabetical order.
    static func templateNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: templatesFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The Templates to offer in a menu: the folder's plus the one already chosen, even if it is gone meanwhile.
    static func templateChoices(including selected: String) -> [String] {
        let names = templateNames()
        return names.contains(selected) ? names : [selected] + names
    }

    /// Creates the default Template (Notes) if the Templates folder has none, or if the
    /// default Template of the Settings no longer exists (then the default becomes Notes).
    static func ensureDefaultTemplate() throws {
        let names = templateNames()
        guard names.isEmpty || !names.contains(AppSettings.defaultTemplate) else { return }
        try FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
        if !names.contains(Template.defaultName) {
            try Template.defaultFileContent.write(to: templateURL(Template.defaultName), atomically: true, encoding: .utf8)
        }
        AppSettings.defaultTemplate = Template.defaultName
    }

    /// Creates a new Template from the default one and returns its file name (without `.md`).
    static func createTemplate(named name: String) throws -> String {
        guard let safeName = VaultNaming.fileName(name) else { throw VaultError.invalidName(name) }
        try FileManager.default.createDirectory(at: templatesFolder, withIntermediateDirectories: true)
        let fileName = VaultNaming.available(safeName, taken: Set(templateNames()))
        try Template.newFileContent(name: fileName)
            .write(to: templateURL(fileName), atomically: true, encoding: .utf8)
        return fileName
    }

    /// Moves the Template to the Trash: it can be recovered.
    static func trashTemplate(named name: String) throws {
        try FileManager.default.trashItem(at: templateURL(name), resultingItemURL: nil)
    }

    static func templateURL(_ name: String) -> URL {
        templatesFolder.appending(path: name + ".md")
    }

    /// The Template with that file name; if it is gone, Notes (as the user edited it),
    /// and only without that the built-in text.
    static func template(named name: String) -> Template {
        for candidate in [name, Template.defaultName] {
            if let content = try? String(contentsOf: templateURL(candidate), encoding: .utf8) {
                return Template(fileName: candidate, content: content)
            }
        }
        return Template(fileName: Template.defaultName, content: Template.defaultFileContent)
    }

    // MARK: - Vocabulary

    /// The Vocabulary: empty if the file is missing or unreadable.
    static func vocabulary() -> Vocabulary {
        (try? String(contentsOf: vocabularyURL, encoding: .utf8)).map(Vocabulary.init(fileContent:)) ?? .empty
    }

    /// Creates the Vocabulary file with the example text if it does not exist.
    static func ensureVocabularyFile() throws {
        guard !FileManager.default.fileExists(atPath: vocabularyURL.path(percentEncoded: false)) else { return }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Vocabulary.exampleFileContent.write(to: vocabularyURL, atomically: true, encoding: .utf8)
    }
}
