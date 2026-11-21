import ApplicationServices
import ChainCore
import Foundation
import OSLog

struct NativeFrameWrite {
    var verified = false
    var size: AXError?
    var position: AXError?
    var before: CGRect?
    var afterSize: CGRect?
    var afterPosition: CGRect?
    var coarsePosition: AXError?
    var afterCoarse: CGRect?
}

enum NativePlacementLog {
    private static let logger = Logger(subsystem: "app.paperchain.mac", category: "placement")

    static func rejected(initial: NativeFrameWrite, latest: NativeFrameWrite, target: CGRect, actual: CGRect?,
                         usable: CGRect, neighbors: [Box], minimized: Bool?, firstSample: CGRect?, beforeRetry: CGRect?) {
        func rect(_ value: CGRect?) -> String {
            guard let value else { return "unreadable" }
            return String(format: "(%.2f,%.2f,%.2f,%.2f)", value.minX, value.minY, value.width, value.height)
        }
        func status(_ value: AXError?) -> String {
            value.map { String($0.rawValue) } ?? "skipped"
        }
        let seams = neighbors.map { rect($0.nativeRect) }.joined(separator: ",")
        let mini = minimized.map { String($0) } ?? "unreadable"
        logger.error("Frame rejected target=\(rect(target), privacy: .public) actual=\(rect(actual), privacy: .public) usable=\(rect(usable), privacy: .public) neighbors=[\(seams, privacy: .public)] minimized=\(mini, privacy: .public)")
        logger.error("Initial before=\(rect(initial.before), privacy: .public) sizeAX=\(status(initial.size), privacy: .public) afterSize=\(rect(initial.afterSize), privacy: .public) positionAX=\(status(initial.position), privacy: .public) afterPosition=\(rect(initial.afterPosition), privacy: .public) firstSample=\(rect(firstSample), privacy: .public)")
        logger.error("Retry before=\(rect(beforeRetry), privacy: .public) coarseAX=\(status(latest.coarsePosition), privacy: .public) afterCoarse=\(rect(latest.afterCoarse), privacy: .public) sizeAX=\(status(latest.size), privacy: .public) afterSize=\(rect(latest.afterSize), privacy: .public) positionAX=\(status(latest.position), privacy: .public) afterPosition=\(rect(latest.afterPosition), privacy: .public)")
    }

    static func parkingFailed(_ reason: StaticString) {
        logger.error("Park rejected reason=\(String(describing: reason), privacy: .public)")
    }
}
