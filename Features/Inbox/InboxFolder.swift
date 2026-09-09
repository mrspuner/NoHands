import Foundation

/// Names and creates the folder of one captured item.
///
/// Shaped after `MeetingFolder` deliberately: the same `yyyy-MM-dd-HHmm-slug` in local time and
/// the same numeric suffix when two of them land in the same minute. Two archives on one disk
/// with two naming rules would be one more thing to remember for no gain — and the reason for
/// local time is the same one: the archive is read by a human who remembers when it happened.
///
/// Unlike a meeting there is no draft state and no dot prefix. A capture is written in one go
/// and nothing downstream waits for it, so there is nothing for an atomic hand-off to protect.
public enum InboxFolder {
    public static var rootURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Inbox")
    }

    /// The last component of a bundle identifier, lower-cased: `ru.keepcoder.Telegram` becomes
    /// `telegram`. Same rule `MeetingsConfig.TriggerApp.resolvedSlug` falls back to.
    ///
    /// `NSRunningApplication` hands back an optional identifier, so the empty case is reachable
    /// rather than defensive — and a folder named `2026-09-08-1732-` would be the shape of it.
    public static func slug(forBundleID bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map { $0.lowercased() } ?? ""
        return last.isEmpty ? "app" : last
    }

    public static func baseName(capturedAt: Date, slug: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "\(formatter.string(from: capturedAt))-\(slug)"
    }

    public static func create(
        in root: URL,
        capturedAt: Date,
        slug: String,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = baseName(capturedAt: capturedAt, slug: slug)
        var candidate = base
        var suffix = 1
        while fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            suffix += 1
            candidate = "\(base)-\(suffix)"
        }
        let folder = root.appendingPathComponent(candidate)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    /// Copies a dropped file into the capture's folder.
    ///
    /// Copied, never moved: the source is somebody else's folder — the Telegram cache, the
    /// Downloads folder — and carrying a file out of it is not this application's business.
    /// A name that is already taken gets the same numeric suffix a folder does, with the
    /// extension kept where it belongs so the file still opens by double-click.
    @discardableResult
    public static func copyAttachment(
        _ source: URL,
        into folder: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let name = source.lastPathComponent
        let ext = source.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var candidate = name
        var suffix = 1
        while fileManager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            suffix += 1
            candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
        }
        let destination = folder.appendingPathComponent(candidate)
        try fileManager.copyItem(at: source, to: destination)
        return destination
    }
}
