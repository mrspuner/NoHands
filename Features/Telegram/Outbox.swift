import Foundation

/// A message waiting in the outbox folder to be sent to the owner.
public struct OutboxMessage: Equatable, Sendable {
    public let url: URL
    /// Inbox item this message is about, if any; replies to it are routed back by this value.
    public let ref: String?
    public let body: String

    public init(url: URL, ref: String?, body: String) {
        self.url = url
        self.ref = ref
        self.body = body
    }
}

public enum Outbox {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoHands/telegram-outbox", isDirectory: true)
    }

    /// `*.md` files not starting with `.`, ascending by name. A writer creates `.<name>.tmp` and
    /// renames it, so a half-written file is never visible here.
    public static func pending(in folder: URL) -> [OutboxMessage] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".md") }
            .sorted()
            .compactMap { name in
                let url = folder.appendingPathComponent(name)
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return parse(url: url, contents: contents)
            }
    }

    /// Optional frontmatter (`---`, `ref: <value>`, `---`) followed by the body.
    public static func parse(url: URL, contents: String) -> OutboxMessage {
        var ref: String?
        var body = contents
        if contents.hasPrefix("---\n"), let close = contents.range(of: "\n---\n", range: contents.index(contents.startIndex, offsetBy: 3)..<contents.endIndex) {
            let header = contents[contents.index(contents.startIndex, offsetBy: 4)..<close.lowerBound]
            for line in header.split(separator: "\n") where line.hasPrefix("ref:") {
                let value = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { ref = value }
            }
            body = String(contents[close.upperBound...])
        }
        return OutboxMessage(url: url, ref: ref, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Writes `yyyyMMdd-HHmmss-<6 hex>.md` via a dot-prefixed temp file and a rename.
    @discardableResult
    public static func write(ref: String?, body: String, to folder: URL, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(6))
        let name = "\(formatter.string(from: now))-\(suffix).md"
        var text = ""
        if let ref { text += "---\nref: \(ref)\n---\n" }
        text += body + "\n"
        let temp = folder.appendingPathComponent(".\(name).tmp")
        let final = folder.appendingPathComponent(name)
        try text.write(to: temp, atomically: false, encoding: .utf8)
        try FileManager.default.moveItem(at: temp, to: final)
        return final
    }
}
