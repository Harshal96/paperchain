import ApplicationServices
import Foundation
import NativeAXMetadata

func errorSlot(_ error: AXError) -> AXValue {
    var error = error
    return AXValueCreate(.axError, &error)!
}

var point = CGPoint(x: -1500, y: 24)
var size = CGSize(width: 800, height: 900)
let attributes: [String: AnyObject] = [
    kAXRoleAttribute: kAXWindowRole as NSString,
    kAXSubroleAttribute: kAXStandardWindowSubrole as NSString,
    kAXPositionAttribute: AXValueCreate(.cgPoint, &point)!,
    kAXSizeAttribute: AXValueCreate(.cgSize, &size)!,
    kAXTitleAttribute: "Document" as NSString,
    kAXIdentifierAttribute: "document-1" as NSString,
    kAXMinimizedAttribute: kCFBooleanFalse,
    "AXFullScreen": errorSlot(.attributeUnsupported)
]

// The fake AX server answers in the order requested, including sparse error slots.
func read(_ overrides: [String: AnyObject] = [:], status: AXError = .success,
          singleStatus: [String: AXError] = [:]) -> (NativeWindowMetadata, [String]) {
    let slots = attributes.merging(overrides) { _, replacement in replacement }
    var singles: [String] = []
    var batches = 0
    let metadata = NativeWindowMetadata.read(multiple: { names in
        batches += 1
        let requested = names as! [String]
        precondition(requested.count == attributes.count && Set(requested) == Set(attributes.keys))
        let values = requested.map { slots[$0] ?? kCFNull! }
        return (status, values as CFArray)
    }, single: { name in
        singles.append(name)
        if let error = singleStatus[name] { return (error, nil) }
        return (.success, attributes[name])
    })
    precondition(batches == 1)
    return (metadata, singles)
}

let (snapshot, singles) = read()
precondition(singles.isEmpty && snapshot.applicable == true && snapshot.frame == CGRect(origin: point, size: size))
precondition(snapshot.title == "Document" && snapshot.identifier == "document-1")
precondition(snapshot.minimized == false && snapshot.fullScreen == false)
let (partial, _) = read([kAXMinimizedAttribute: errorSlot(.cannotComplete), "AXFullScreen": errorSlot(.noValue),
                         kAXIdentifierAttribute: kCFNull!])
precondition(partial.applicable == true && partial.frame == snapshot.frame && partial.identifier == nil)
precondition(partial.fullScreen == nil && partial.minimized == nil)
let (ambiguous, resolved) = read(["AXFullScreen": kCFNull!], singleStatus: ["AXFullScreen": .attributeUnsupported])
precondition(ambiguous.fullScreen == false && resolved == ["AXFullScreen"])
precondition(read([kAXRoleAttribute: "AXButton" as NSString]).0.applicable == false)
precondition(read([kAXSubroleAttribute: "AXDialog" as NSString]).0.applicable == false)
precondition(read([kAXRoleAttribute: errorSlot(.cannotComplete)]).0.applicable == nil)
let (required, recovered) = read([kAXPositionAttribute: errorSlot(.notImplemented)])
precondition(required.frame == snapshot.frame && recovered == [kAXPositionAttribute])
precondition(read([kAXPositionAttribute: attributes[kAXSizeAttribute]!]).0.frame == nil)
precondition(read(["AXFullScreen": "unknown" as NSString]).0.fullScreen == nil)
let (legacy, legacyReads) = read(status: .notImplemented, singleStatus: ["AXFullScreen": .attributeUnsupported])
precondition(legacy.frame == snapshot.frame && legacy.fullScreen == false &&
             legacyReads.count == 8 && Set(legacyReads) == Set(attributes.keys))
let (timedOut, timeoutReads) = read(status: .cannotComplete)
precondition(timedOut.applicable == nil && timeoutReads.isEmpty)
print("Native AX metadata checks passed (one batch, eight fallback attributes, partial results and timeouts).")
