import ApplicationServices
import CoreGraphics

/// An accessibility element and what is under it, read in one pass: a
/// reader looks for a chat in it without asking the app again, and tests
/// build one by hand. Frames are in accessibility coordinates: global
/// points, top-left origin.
struct AXNode: Sendable, Equatable {
    var role: String
    var frame: CGRect?
    /// The longest of its value, title and description.
    var text = ""
    /// Its value can be set: an input box.
    var editable = false
    var children: [AXNode] = []

    /// Every element under this one, nearest first.
    var descendants: [AXNode] {
        children.flatMap { [$0] + $0.descendants }
    }

    func all(_ role: String) -> [AXNode] {
        descendants.filter { $0.role == role }
    }
}

enum AXSnapshot {
    /// The front window of `pid`, read whole, or nil when the app shows none.
    /// Stops after `limit` elements: a chat app's window holds a few hundred.
    static func window(pid: pid_t, limit: Int = 5000) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 1.0)
        guard let window = AX.element(AX.attr(app, kAXFocusedWindowAttribute)) ?? AX.element(AX.attr(app, kAXMainWindowAttribute))
        else { return nil }
        var budget = limit
        return node(window, depth: 0, budget: &budget)
    }

    private static let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXValueAttribute,
                                kAXTitleAttribute, kAXDescriptionAttribute, kAXChildrenAttribute, kAXRowsAttribute] as CFArray

    private static func node(_ element: AXUIElement, depth: Int, budget: inout Int) -> AXNode {
        budget -= 1
        var raw: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
        let values = (raw as? [AnyObject]) ?? []
        let value = { (index: Int) -> CFTypeRef? in
            guard index < values.count else { return nil }
            let item = values[index] as CFTypeRef
            // A missing attribute comes back as an error in its place.
            if CFGetTypeID(item) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
        let role = value(0) as? String ?? ""
        var node = AXNode(role: role)
        if let origin = AX.point(value(1)), let size = AX.size(value(2)) { node.frame = CGRect(origin: origin, size: size) }
        node.text = [value(3) as? String, value(4) as? String, value(5) as? String]
            .compactMap { $0 }.max { $0.count < $1.count } ?? ""
        if role == kAXTextAreaRole || role == kAXTextFieldRole {
            var settable = DarwinBoolean(false)
            node.editable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                && settable.boolValue
        }
        guard depth < 40 else { return node }
        // A table lists its cells under its rows and again under its
        // columns; the rows alone hold each once.
        var kids = (value(6) as? [AXUIElement]) ?? []
        if role == kAXTableRole, let rows = value(7) as? [AXUIElement], !rows.isEmpty {
            kids = rows + kids.filter { ![kAXRowRole, kAXColumnRole].contains(AX.string($0, kAXRoleAttribute) ?? "") }
        }
        for kid in kids where budget > 0 {
            node.children.append(Self.node(kid, depth: depth + 1, budget: &budget))
        }
        return node
    }
}
