import Foundation
import Observation

@MainActor
@Observable
final class CallHistoryStore {
    static let shared = CallHistoryStore()

    private(set) var records: [CallHistoryRecord] = []
    private(set) var lastError: String?

    private let folderURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init(fileManager: FileManager = .default) {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        folderURL = base
            .appendingPathComponent("Voxa", isDirectory: true)
            .appendingPathComponent("CallHistory", isDirectory: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        print("[History] store init folder=\(folderURL.path)")
        reload()
    }

    func reload() {
        do {
            try ensureFolderExists()
            print("[History] reload begin folder=\(folderURL.path)")
            let urls = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            let jsonURLs = urls.filter { $0.pathExtension == "json" }
            var loaded: [CallHistoryRecord] = []
            var failed = 0
            for url in jsonURLs {
                do {
                    let record = try loadRecord(at: url)
                    loaded.append(record)
                    print(
                        "[History] reload decoded file=\(url.lastPathComponent) id=\(record.id) turns=\(record.turns.count) title=\"\(record.displayTitle)\""
                    )
                } catch {
                    failed += 1
                    print("[History] reload decode failed file=\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            records = loaded
                .sorted { $0.startedAt > $1.startedAt }
            lastError = nil
            print("[History] reload done jsonFiles=\(jsonURLs.count) loaded=\(records.count) failed=\(failed)")
        } catch {
            lastError = error.localizedDescription
            print("[History] reload failed: \(error.localizedDescription)")
        }
    }

    func upsert(_ record: CallHistoryRecord, preserveManualTitle: Bool = true) {
        do {
            try ensureFolderExists()
            var recordToSave = record
            if preserveManualTitle,
               let existing = try? loadRecord(at: fileURL(for: record.id)),
               let manualTitle = existing.manualTitle,
               !manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordToSave.manualTitle = manualTitle
                print("[History] preserving manual title id=\(record.id) title=\"\(manualTitle)\"")
            }
            let data = try encoder.encode(recordToSave)
            let url = fileURL(for: record.id)
            try data.write(to: url, options: [.atomic])
            mergeInMemory(recordToSave)
            lastError = nil
            print(
                "[History] saved call id=\(record.id) file=\(url.path) bytes=\(data.count) turns=\(record.turns.count) manualTitle=\"\(recordToSave.manualTitle ?? "")\" generatedTitle=\"\(recordToSave.generatedTitle ?? "")\" display=\"\(recordToSave.displayTitle)\""
            )
        } catch {
            lastError = error.localizedDescription
            print("[History] save failed id=\(record.id): \(error.localizedDescription)")
        }
    }

    func setManualTitle(_ title: String, for recordID: UUID) {
        guard var record = records.first(where: { $0.id == recordID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        record.manualTitle = trimmed.isEmpty ? nil : trimmed
        print("[History] manual title update id=\(recordID) chars=\(trimmed.count) title=\"\(trimmed)\"")
        upsert(record, preserveManualTitle: false)
    }

    private func mergeInMemory(_ record: CallHistoryRecord) {
        if let idx = records.firstIndex(where: { $0.id == record.id }) {
            records[idx] = record
        } else {
            records.append(record)
        }
        records.sort { $0.startedAt > $1.startedAt }
    }

    private func loadRecord(at url: URL) throws -> CallHistoryRecord {
        let data = try Data(contentsOf: url)
        return try decoder.decode(CallHistoryRecord.self, from: data)
    }

    private func ensureFolderExists() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        folderURL.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
