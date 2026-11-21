import AppKit
import ApplicationServices
import ChainCore
import CryptoKit
import NativeAXMetadata

/// Accessibility and Quartz use global points measured downwards from the primary display.
extension Box {
    init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    var nativeRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

enum NativeAX {
    private static let frameAttributes = [kAXPositionAttribute, kAXSizeAttribute] as CFArray

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let item = attribute(element, name), CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
        return (item as! AXUIElement)
    }

    static func settable(_ element: AXUIElement, _ name: String) -> Bool {
        settableState(element, name) == true
    }

    static func settableState(_ element: AXUIElement, _ name: String) -> Bool? {
        var result = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &result)
        if status == .attributeUnsupported { return false }
        return status == .success ? result.boolValue : nil
    }

    static func flag(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name) as? Bool
    }

    @discardableResult
    static func setFlag(_ element: AXUIElement, _ name: String, _ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, frameAttributes, [], &values)
        if status == .success, let pair = values as? [AnyObject], pair.count == 2,
           let frame = NativeWindowMetadata.frame(position: pair[0], size: pair[1]) { return frame }
        // Some AX servers support individual attributes but return per-attribute
        // errors in a batch. Preserve their existing single-attribute path.
        guard status == .success || status == .notImplemented || status == .attributeUnsupported,
              let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { return nil }
        return NativeWindowMetadata.frame(position: position, size: size)
    }

    static func setSize(_ size: CGSize, of element: AXUIElement) -> AXError {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    static func setOrigin(_ point: CGPoint, of element: AXUIElement) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .illegalArgument }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    static func applicability(_ element: AXUIElement) -> Bool? {
        guard let role = attribute(element, kAXRoleAttribute) as? String else { return nil }
        guard role == kAXWindowRole else { return false }
        guard let subrole = attribute(element, kAXSubroleAttribute) as? String else { return nil }
        return subrole == kAXStandardWindowSubrole
    }

    static func identityHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct NativeWindowNumber {
    let number: CGWindowID
    let frame: CGRect

    /// Owner, number, bounds and layer are public Quartz metadata. No pixel or title access.
    static func inventory() -> [pid_t: [NativeWindowNumber]] {
        guard let rows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var result: [pid_t: [NativeWindowNumber]] = [:]
        for row in rows {
            guard row[kCGWindowLayer as String] as? Int == 0,
                  let pid = row[kCGWindowOwnerPID as String] as? Int32,
                  let number = row[kCGWindowNumber as String] as? UInt32,
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds) else { continue }
            result[pid, default: []].append(NativeWindowNumber(number: number, frame: frame))
        }
        return result
    }
}

extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    func bounded(in limits: CGRect) -> CGRect {
        let size = CGSize(width: min(width, limits.width), height: min(height, limits.height))
        return CGRect(origin: boundedOrigin(for: size, in: limits), size: size)
    }

    func boundedOrigin(for size: CGSize, in limits: CGRect) -> CGPoint {
        CGPoint(x: max(limits.minX, min(minX, limits.maxX - size.width)),
                y: max(limits.minY, min(minY, limits.maxY - size.height)))
    }
}
