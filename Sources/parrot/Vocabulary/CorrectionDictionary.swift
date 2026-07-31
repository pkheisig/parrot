import Foundation

struct CorrectionEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var alias: String
    var canonical: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        alias: String,
        canonical: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.alias = alias
        self.canonical = canonical
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct CorrectionProposal: Equatable {
    var alias: String
    var canonical: String
}

extension Notification.Name {
    static let parrotDictionaryDidChange = Notification.Name(
        "com.pkheisig.parrot.dictionary-did-change"
    )
}

/// Thread-safe, universal correction dictionary shared by both language paths.
///
/// Canonical terms are used as decoder prompts after language recognition.
/// Aliases are also applied deterministically to the finished transcript.
final class CorrectionDictionaryStore: @unchecked Sendable {
    private let lock = NSLock()
    private let fileURL: URL?
    private var storedEntries: [CorrectionEntry]

    init(
        fileURL: URL? = nil,
        persistent: Bool = true,
        initialEntries: [CorrectionEntry] = []
    ) {
        let resolvedURL = persistent ? (fileURL ?? Self.defaultFileURL()) : nil
        self.fileURL = resolvedURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let resolvedURL,
           let data = try? Data(contentsOf: resolvedURL),
           let decoded = try? decoder.decode([CorrectionEntry].self, from: data) {
            self.storedEntries = decoded
        } else {
            self.storedEntries = initialEntries
        }
    }

    var entries: [CorrectionEntry] {
        lock.withLock {
            storedEntries.sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending
            }
        }
    }

    @discardableResult
    func upsert(alias: String, canonical: String) -> CorrectionEntry? {
        let alias = Self.clean(alias)
        let canonical = Self.clean(canonical)
        guard Self.isValid(alias), Self.isValid(canonical), alias != canonical else {
            return nil
        }

        let changed: CorrectionEntry? = lock.withLock {
            if let index = storedEntries.firstIndex(where: {
                Self.normalized($0.alias) == Self.normalized(alias)
            }) {
                storedEntries[index].alias = alias
                storedEntries[index].canonical = canonical
                storedEntries[index].updatedAt = Date()
                persistLocked()
                return storedEntries[index]
            }
            let entry = CorrectionEntry(alias: alias, canonical: canonical)
            storedEntries.append(entry)
            persistLocked()
            return entry
        }
        if changed != nil { notifyChanged() }
        return changed
    }

    func update(id: UUID, alias: String, canonical: String) -> Bool {
        let alias = Self.clean(alias)
        let canonical = Self.clean(canonical)
        guard Self.isValid(alias), Self.isValid(canonical), alias != canonical else {
            return false
        }

        let changed = lock.withLock {
            guard storedEntries.contains(where: { $0.id == id }) else {
                return false
            }
            storedEntries.removeAll {
                $0.id != id && Self.normalized($0.alias) == Self.normalized(alias)
            }
            guard let index = storedEntries.firstIndex(where: { $0.id == id }) else {
                return false
            }
            storedEntries[index].alias = alias
            storedEntries[index].canonical = canonical
            storedEntries[index].updatedAt = Date()
            persistLocked()
            return true
        }
        if changed { notifyChanged() }
        return changed
    }

    func remove(id: UUID) {
        let changed = lock.withLock {
            let previousCount = storedEntries.count
            storedEntries.removeAll { $0.id == id }
            guard storedEntries.count != previousCount else { return false }
            persistLocked()
            return true
        }
        if changed { notifyChanged() }
    }

    func apply(to text: String) -> String {
        var result = text
        let replacements = entries.sorted {
            $0.alias.utf16.count > $1.alias.utf16.count
        }
        for entry in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: entry.alias)
            let pattern = #"(?<![\p{L}\p{N}])\#(escaped)(?![\p{L}\p{N}])"#
            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else { continue }
            let fullRange = NSRange(result.startIndex..., in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: fullRange,
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.canonical)
            )
        }
        return result
    }

    /// Keeps prompts short enough for Whisper's prompt context while preferring
    /// the newest learned spellings.
    func promptText(maximumCharacters: Int = 700) -> String? {
        var seen = Set<String>()
        var terms: [String] = []
        var length = 0
        for entry in entries {
            let key = Self.normalized(entry.canonical)
            guard seen.insert(key).inserted else { continue }
            let addedLength = entry.canonical.count + (terms.isEmpty ? 0 : 2)
            guard length + addedLength <= maximumCharacters else { break }
            terms.append(entry.canonical)
            length += addedLength
        }
        guard !terms.isEmpty else { return nil }
        return "Preferred vocabulary: \(terms.joined(separator: ", "))."
    }

    private func persistLocked() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(storedEntries).write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data(
                "dictionary save failed: \(error)\n".utf8
            ))
        }
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .parrotDictionaryDidChange, object: self)
    }

    private static func defaultFileURL() -> URL? {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        return base
            .appendingPathComponent("Parrot", isDirectory: true)
            .appendingPathComponent("Dictionary", isDirectory: true)
            .appendingPathComponent("corrections.json")
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        clean(value).lowercased()
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 160
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
