import ApplicationServices
import Foundation

package struct NativeWindowMetadata {
    package private(set) var applicable: Bool?
    package private(set) var frame: CGRect?
    package private(set) var title: String?
    package private(set) var identifier: String?
    package private(set) var minimized: Bool?
    package private(set) var fullScreen: Bool?

    private enum Field: Int {
        case role, subrole, position, size, title, identifier, minimized, fullScreen
    }
    private static let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
                                kAXTitleAttribute, kAXIdentifierAttribute, kAXMinimizedAttribute, "AXFullScreen"]
    private static let attributes = names as CFArray

    package static func read(_ element: AXUIElement) -> Self {
        read(multiple: { names in
            var values: CFArray?
            let status = AXUIElementCopyMultipleAttributeValues(element, names, [], &values)
            return (status, values)
        }, single: { name in
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (status, value)
        })
    }

    package static func read(multiple: (CFArray) -> (AXError, CFArray?),
                             single: (String) -> (AXError, CFTypeRef?)) -> Self {
        var item = Self()
        let (status, values) = multiple(attributes)
        // AXWindows can still contain the handle during a close. Let inventory verify
        // its removal instead of preserving it like a window whose AX calls timed out.
        if status == .invalidUIElement { item.applicable = false; return item }
        guard status == .success || status == .notImplemented || status == .attributeUnsupported else { return item }
        let batch = status == .success ? values as? [AnyObject] : nil
        func readSlot(_ field: Field, required: Bool) -> (AXError, CFTypeRef?) {
            let index = field.rawValue
            guard let batch, batch.count == names.count else { return single(names[index]) }
            let value = batch[index]
            if CFGetTypeID(value) == CFNullGetTypeID() {
                // A null cannot distinguish an unsupported fullscreen flag from a
                // temporarily missing value. Only the former confirms ordinary mode.
                return required || field == .fullScreen ? single(names[index]) : (.noValue, nil)
            }
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var error = AXError.failure
                AXValueGetValue(value as! AXValue, .axError, &error)
                if error == .notImplemented || required && error == .attributeUnsupported { return single(names[index]) }
                return (error, nil)
            }
            return (.success, value)
        }
        func slot(_ field: Field, required: Bool = false) -> (AXError, CFTypeRef?) {
            let result = readSlot(field, required: required)
            if result.0 == .invalidUIElement { item.applicable = false }
            return result
        }
        func value(_ field: Field, required: Bool = false) -> CFTypeRef? {
            let (error, value) = slot(field, required: required)
            return error == .success ? value : nil
        }
        func flag(_ field: Field, unsupported: Bool? = nil) -> Bool? {
            let (error, value) = slot(field)
            if error == .attributeUnsupported { return unsupported }
            return error == .success ? value as? Bool : nil
        }

        guard let role = value(.role, required: true) as? String else { return item }
        guard role == kAXWindowRole else { item.applicable = false; return item }
        guard let subrole = value(.subrole, required: true) as? String else { return item }
        item.applicable = subrole == kAXStandardWindowSubrole
        guard item.applicable == true, let pos = value(.position, required: true),
              let size = value(.size, required: true), let rect = frame(position: pos, size: size) else { return item }
        item.frame = rect
        item.title = value(.title) as? String
        item.identifier = value(.identifier) as? String
        item.minimized = flag(.minimized)
        item.fullScreen = flag(.fullScreen, unsupported: false)
        return item
    }

    package static func frame(position: CFTypeRef, size: CFTypeRef) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent),
              point.x.isFinite, point.y.isFinite, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}
