import ChainCore
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

private typealias Journal = NativeParkingJournal
private typealias Record = Journal.Record

private func expect(_ value: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    guard value() else { fatalError("Line \(line): \(message)") }
}

private func expectFailure(_ message: String, _ perform: () throws -> Void) {
    do { try perform() } catch { return }
    fatalError(message)
}

private func window(_ id: String, pid: Int32 = 44, launch: Double = 1500,
                    bundle: String = "example.editor", identifier: String? = nil,
                    title: String = "Draft", frame: CGRect = CGRect(x: -300, y: 200, width: 500, height: 400)) -> Record {
    Record(pid: pid, launchTime: launch, bundleID: bundle, id: id, identifier: identifier, title: title, frame: frame)
}

@MainActor
private func checkMatching() {
    let stored = window("old")
    let candidate = window("new")
    let duplicate = window("unrelated")
    expect(Journal.match(stored, among: [candidate]) == candidate, "recover unique title and frame after restart")
    expect(Journal.match(stored, among: [candidate, duplicate]) == nil, "identical title and frame are ambiguous")
    let moved = window("moved", frame: stored.frame.offsetBy(dx: 1, dy: 0))
    expect(Journal.match(stored, among: [moved, window("renamed", title: "Other")]) == nil,
           "both title and frame must agree for recovery without an identifier")
    expect(Journal.match(stored, among: [window("wrong-pid", pid: 45), window("relaunch", launch: 1600),
                                         window("wrong-app", bundle: "example.viewer")]) == nil,
           "records match only the original app launch")

    let named = window("before", identifier: "a:document")
    let namedNow = window("after", identifier: "a:document", title: "Renamed", frame: .zero)
    expect(Journal.match(named, among: [namedNow, duplicate]) == namedNow,
           "a stable identifier survives a change of title or frame")
    expect(Journal.match(named, among: [candidate]) == nil, "an absent AX identifier cannot fall back to another document")
    let quartz = window("old-quartz", identifier: "q:741")
    let conflicting = window("other-quartz", identifier: "q:742")
    expect(Journal.canRecover(named, among: [named, duplicate]),
           "a unique AX identifier permits parking with otherwise identical siblings")
    expect(!Journal.canRecover(stored, among: [stored, duplicate]), "ambiguous windows cannot be parked")
    expect(!Journal.canRecover(quartz, among: [quartz, conflicting]),
           "different Quartz numbers may both disappear during parking")
    expect(Journal.canRecover(quartz, among: [quartz, window("stale", launch: 1600)]),
           "an identically shaped window from another app launch does not block parking")
    expect(Journal.match(quartz, among: [candidate, conflicting]) == candidate,
           "a minimized Quartz window can lose its number")
    expect(Journal.match(quartz, among: [conflicting]) == nil, "a different Quartz number cannot be restored")
    expect(Journal.match(quartz, among: [candidate, duplicate]) == nil, "missing Quartz number requires unique evidence")
    expect(Journal.match(window("bad", launch: 0), among: [window("bad", launch: 0)]) == nil,
           "missing launch time cannot establish ownership")
}

@MainActor
private func checkPersistence(in directory: URL) throws {
    let manager = FileManager.default
    let folder = directory.appendingPathComponent("store")
    let file = folder.appendingPathComponent("parked.json")
    let journal = Journal(fileURL: file)
    let initial = window("a")
    let updated = window("a", title: "Revision 2")
    let second = window("b")
    expect(journal.records.isEmpty, "first run")
    try journal.remember(initial)
    try journal.remember(initial)
    try journal.remember(second)
    try journal.remember(updated)
    let reloaded = Journal(fileURL: file)
    expect(reloaded.records.count == 2 && reloaded.record(for: "a") == updated && reloaded.record(for: "b") == second,
           "records survive restart and replace earlier observations by identity")
    try reloaded.forget("missing")
    try reloaded.forget("a")
    expect(Journal(fileURL: file).records == [second], "forget survives restart")

    // A regular file in place of the containing directory fails even under privileged test runners.
    let displaced = directory.appendingPathComponent("saved")
    try manager.moveItem(at: folder, to: displaced)
    try Data("unwritable path".utf8).write(to: folder)
    expectFailure("failed remember must throw") { try reloaded.remember(initial) }
    expectFailure("failed forget must throw") { try reloaded.forget("b") }
    expect(reloaded.records == [second], "failed mutations leave ownership intact in memory")
    try manager.removeItem(at: folder)
    try manager.moveItem(at: displaced, to: folder)
    expect(Journal(fileURL: file).records == [second], "last persisted ownership is recoverable after a write failure")

    let corrupt = Data("partial document".utf8)
    try corrupt.write(to: file)
    let unreadable = Journal(fileURL: file)
    expectFailure("cannot overwrite an undecodable journal") { try unreadable.remember(initial) }
    expectFailure("cannot forget through an undecodable journal") { try unreadable.forget("b") }
    let preserved = try Data(contentsOf: file)
    expect(preserved == corrupt && unreadable.records.isEmpty, "corrupt recovery data is preserved verbatim")
}

private func checkRestore() {
    for intent in [ParkingRestore.Intent.show, .release] {
        var attempt = ParkingRestore(intent)
        expect(attempt.check(minimized: true) == .retry, "acceptance alone cannot confirm a restore")
        expect(attempt.check(minimized: true) == .exhausted, "only one restore retry is allowed")
        expect(attempt.check(minimized: nil) == .exhausted, "unknown state cannot extend the retry budget")
        expect(attempt.check(minimized: false) == .confirmed, "a late visible observation can confirm the restore")

        var unknown = ParkingRestore(intent)
        expect(unknown.check(minimized: nil) == .wait, "allow one follow-up observation for missing AX state")
        expect(unknown.check(minimized: true) == .exhausted, "a wait consumes the same bounded budget")
    }

    var reversed = ParkingRestore(.show)
    reversed.intent = .park
    expect(reversed.check(minimized: true) == .wait, "a newer park intent waits for an in-flight restore")
    expect(reversed.check(minimized: true) == .keepParked, "a newer park intent never retries the old restore")
    expect(reversed.check(minimized: false) == .confirmed && reversed.intent == .park,
           "the caller can apply the latest park intent when a late restore is confirmed")

    var afterRetry = ParkingRestore(.show)
    expect(afterRetry.check(minimized: true) == .retry, "schedule one retry to show the window")
    afterRetry.intent = .park
    expect(afterRetry.check(minimized: nil) == .keepParked, "changing intent does not restart the two-check budget")
}

private let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("journal-checks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: temporary) }
checkRestore()
try await MainActor.run {
    checkMatching()
    try checkPersistence(in: temporary)
}
print("Parking journal checks passed")
