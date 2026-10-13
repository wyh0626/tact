import AppKit
import ApplicationServices

/// What the app knows about the focused input box at one moment. All rects
/// are in accessibility coordinates: global, origin at the top-left of the
/// primary screen.
struct InputSnapshot {
    let element: AXUIElement
    let value: String
    let frame: CGRect
    let caret: CGRect?
    let windowFrame: CGRect
}

enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v = v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    static func range(_ v: CFTypeRef?) -> CFRange? {
        guard let v = v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CFRange(location: 0, length: 0)
        return AXValueGetValue(v as! AXValue, .cfRange, &r) ? r : nil
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = point(attr(el, kAXPositionAttribute)),
              let s = size(attr(el, kAXSizeAttribute)) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func bounds(_ el: AXUIElement, location: Int, length: Int) -> CGRect? {
        var r = CFRange(location: location, length: length)
        guard let rv = AXValueCreate(.cfRange, &r) else { return nil }
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                el, kAXBoundsForRangeParameterizedAttribute as CFString, rv, &out) == .success,
              let result = rect(out), result.height > 0 else { return nil }
        return result
    }

    /// Caret position: the bounds of the empty selection, or the right edge of
    /// the character before it.
    static func caret(_ el: AXUIElement) -> CGRect? {
        guard let sel = range(attr(el, kAXSelectedTextRangeAttribute)) else { return nil }
        if let r = bounds(el, location: sel.location, length: 0) { return r }
        if sel.location > 0, let r = bounds(el, location: sel.location - 1, length: 1) {
            return CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height)
        }
        return nil
    }

    /// The focused text input of the given app, or nil when focus is not in
    /// a text area or text field.
    static func inputSnapshot(pid: pid_t) -> InputSnapshot? {
        let app = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetMessagingTimeout(app, 1.0)
        guard let focused = element(attr(app, kAXFocusedUIElementAttribute)) else { return nil }
        let role = string(focused, kAXRoleAttribute) ?? ""
        guard role == kAXTextAreaRole || role == kAXTextFieldRole else { return nil }
        guard let inputFrame = frame(focused) else { return nil }
        let window = element(attr(app, kAXFocusedWindowAttribute)) ?? element(attr(focused, kAXWindowAttribute))
        guard let w = window, let windowFrame = frame(w) else { return nil }
        return InputSnapshot(
            element: focused,
            value: string(focused, kAXValueAttribute) ?? "",
            frame: inputFrame,
            caret: caret(focused),
            windowFrame: windowFrame
        )
    }

    @discardableResult
    static func setValue(_ el: AXUIElement, _ text: String) -> Bool {
        AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success
    }

    static func select(_ el: AXUIElement, location: Int, length: Int) {
        var r = CFRange(location: location, length: length)
        if let v = AXValueCreate(.cfRange, &r) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
    }
}
