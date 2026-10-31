import CryptoKit
import Foundation

// MARK: - Library on disk

/// The folder that holds everything the app stores: imported files and, later, thumbnails and the
/// SQLite database. Keeping it all under one root is what lets `LibrarySizeMonitor` account for it.
nonisolated struct DocumentLibrary: Sendable {
    let root: URL

    static let `default` = DocumentLibrary(
        root: .applicationSupportDirectory.appending(path: "DocumentLibrary", directoryHint: .isDirectory)
    )

    /// Copies data into a library subfolder, named by SHA-256 so identical content is stored once.
    /// Originals go in `Files`, generated PDFs for paged documents in `Renditions`.
    /// Returns the path relative to `root`.
    @discardableResult
    func store(_ data: Data, pathExtension: String, in folder: Folder = .files) throws -> String {
        let directory = root.appending(path: folder.rawValue, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = pathExtension.isEmpty ? hash : "\(hash).\(pathExtension.lowercased())"
        let url = directory.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try data.write(to: url, options: .atomic)
        }
        return "\(folder.rawValue)/\(name)"
    }

    enum Folder: String, Sendable {
        case files = "Files"
        case renditions = "Renditions"
    }

    func url(forStoredPath path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    /// Walks the whole library, including hidden files such as SQLite's `-wal`/`-shm`. Blocking.
    func measureUsage() -> LibraryUsage {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return LibraryUsage()
        }
        var usage = LibraryUsage()
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            usage.bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            usage.fileCount += 1
        }
        return usage
    }
}

/// Space the library occupies on disk (allocated size, not logical length).
nonisolated struct LibraryUsage: Equatable, Sendable {
    var bytes: Int64 = 0
    var fileCount = 0

    var formattedSize: String { bytes.formatted(.byteCount(style: .file, spellsOutZero: false)) }
}

// MARK: - Size monitor

/// Keeps `usage` current. Everything in the library is written by the app, so writers call
/// `setNeedsUpdate()`; bursts of calls (e.g. a bulk import) coalesce into a single rescan.
@Observable
final class LibrarySizeMonitor {
    private(set) var usage: LibraryUsage?

    @ObservationIgnored private let library: DocumentLibrary
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRescan = false

    init(library: DocumentLibrary) {
        self.library = library
        setNeedsUpdate()
    }

    func setNeedsUpdate() {
        needsRescan = true
        guard refreshTask == nil else { return }
        refreshTask = Task {
            while needsRescan {
                try? await Task.sleep(for: .milliseconds(250))
                // Writes during the pause are covered by this scan; writes during the scan trigger another.
                needsRescan = false
                usage = await Self.measure(library)
            }
            refreshTask = nil
        }
    }

    @concurrent
    private static func measure(_ library: DocumentLibrary) async -> LibraryUsage {
        library.measureUsage()
    }
}
