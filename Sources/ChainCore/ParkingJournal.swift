import Foundation
#if canImport(CoreGraphics)
// Apple provides CGRect's Codable and Equatable conformances in this overlay.
import CoreGraphics
#endif

/// Records ownership before AX minimizes a window. A fresh manager can then
/// restore its predecessor's windows, even if their in-memory IDs have changed.
@MainActor
package final class NativeParkingJournal {
    package struct Record: Codable, Equatable {
        package let pid: Int32
        package let launchTime: TimeInterval
        package let bundleID: String
        package let id: String
        package let identifier: String?
        package let title: String
        package let frame: CGRect

        package init(pid: Int32, launchTime: TimeInterval, bundleID: String, id: String,
                     identifier: String?, title: String, frame: CGRect) {
            self.pid = pid
            self.launchTime = launchTime
            self.bundleID = bundleID
            self.id = id
            self.identifier = identifier
            self.title = title
            self.frame = frame
        }
    }

    private let fileURL: URL
    private var loadError: Error?
    package private(set) var records: [Record] = []

    package init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Paper Chain/parked-windows-v1.json")
        do {
            let data = try Data(contentsOf: self.fileURL)
            records = try JSONDecoder().decode([Record].self, from: data)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A first run has no parked windows.
        } catch {
            // Preserve the existing file if it is inaccessible or undecodable.
            loadError = error
        }
    }

    package func record(for id: String) -> Record? {
        records.first { $0.id == id }
    }

    package func remember(_ record: Record) throws {
        if let loadError { throw loadError }
        if self.record(for: record.id) == record { return }
        try persist(records.filter { $0.id != record.id } + [record])
    }

    package func forget(_ id: String) throws {
        if let loadError { throw loadError }
        guard record(for: id) != nil else { return }
        try persist(records.filter { $0.id != id })
    }

    private func persist(_ updated: [Record]) throws {
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: fileURL, options: .atomic)
        records = updated
    }

    private static func sameProcess(as stored: Record, among candidates: [Record]) -> [Record] {
        guard stored.pid > 0, stored.launchTime.isFinite, stored.launchTime > 0 else { return [] }
        return candidates.filter {
            $0.pid == stored.pid && $0.launchTime == stored.launchTime && $0.bundleID == stored.bundleID
        }
    }

    private static func matchTitleAndFrame(_ stored: Record, among possible: [Record]) -> Record? {
        guard !stored.title.isEmpty, !stored.frame.isEmpty else { return nil }
        let matching = possible.filter { $0.title == stored.title && $0.frame == stored.frame }
        return matching.count == 1 ? matching[0] : nil
    }

    /// Check before parking, while the complete inventory still has Quartz numbers.
    /// All those numbers could be unavailable on the next launch.
    package static func canRecover(_ record: Record, among candidates: [Record]) -> Bool {
        let possible = sameProcess(as: record, among: candidates)
        if let identifier = record.identifier, !identifier.isEmpty, !identifier.hasPrefix("q:") {
            let identified = possible.filter { $0.identifier == identifier }
            return identified.count == 1 && identified[0].id == record.id
        }
        return matchTitleAndFrame(record, among: possible)?.id == record.id
    }

    /// The caller supplies the complete window inventory, including minimized
    /// and visible windows. A match is only eligible within the same app launch.
    package static func match(_ stored: Record, among candidates: [Record]) -> Record? {
        var possible = sameProcess(as: stored, among: candidates)
        if let identifier = stored.identifier, !identifier.isEmpty {
            let identified = possible.filter { $0.identifier == identifier }
            if identified.count == 1 { return identified[0] }
            if identified.isEmpty, identifier.hasPrefix("q:"), UInt32(identifier.dropFirst(2)) != nil {
                // Minimized windows can disappear from the public Quartz list.
                possible = possible.filter { $0.identifier == nil }
            } else {
                possible = identified
            }
        }

        return matchTitleAndFrame(stored, among: possible)
    }
}
