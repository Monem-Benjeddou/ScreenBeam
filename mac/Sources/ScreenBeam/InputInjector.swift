import ApplicationServices
import CoreGraphics
import Foundation

/// Turns remote input messages from the phone into real macOS mouse and keyboard events.
/// Needs Accessibility permission. All calls on one serial queue.
final class InputInjector {
    /// Display the phone is viewing; absolute coordinates map onto it and the cursor stays on it.
    var displayID: CGDirectDisplayID = CGMainDisplayID()

    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<Int> = []
    private var keysDown: Set<UInt16> = []
    private var flags: CGEventFlags = []
    private var lastClick = (time: Date.distantPast, location: CGPoint.zero, count: 0)
    private var warnedNoPermission = false
    // Diagnostics: what arrived from the phone, logged every few seconds while input flows.
    private var counts: [MessageType: Int] = [:]
    private var lastReport = Date()

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func handle(_ type: MessageType, _ payload: Data) {
        counts[type, default: 0] += 1
        if Date().timeIntervalSince(lastReport) > 5 {
            let summary = counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            Log.write("input (5s): \(summary) trusted=\(Self.isTrusted) held=\(keysDown.sorted()) buttons=\(buttonsDown.sorted())")
            counts.removeAll()
            lastReport = Date()
        }
        guard Self.isTrusted else {
            if !warnedNoPermission {
                warnedNoPermission = true
                Log.write("input ignored: Accessibility permission not granted")
                DispatchQueue.main.async { Self.requestTrust() }
            }
            return
        }
        var r = ByteReader(payload)
        switch type {
        case .mouseMove:
            guard let dx = r.uint(UInt16.self), let dy = r.uint(UInt16.self) else { return }
            moveRelative(dx: Int(Int16(bitPattern: dx)), dy: Int(Int16(bitPattern: dy)))
        case .mouseMoveAbsolute:
            guard let x = r.uint(UInt16.self), let y = r.uint(UInt16.self) else { return }
            let b = CGDisplayBounds(displayID)
            moveTo(CGPoint(x: b.minX + b.width * CGFloat(x) / 65535, y: b.minY + b.height * CGFloat(y) / 65535),
                   dx: 0, dy: 0)
        case .mouseButton:
            guard let button = r.u8(), let down = r.u8() else { return }
            mouseButton(Int(button), down: down != 0)
        case .scroll:
            guard let dx = r.uint(UInt16.self), let dy = r.uint(UInt16.self) else { return }
            scroll(dx: Int32(Int16(bitPattern: dx)), dy: Int32(Int16(bitPattern: dy)))
        case .key:
            guard let code = r.uint(UInt16.self), let down = r.u8() else { return }
            key(code, down: down != 0)
        case .text:
            typeText(String(decoding: payload, as: UTF8.self))
        default:
            break
        }
    }

    /// Lifts everything still held, so a dropped connection never leaves W or the mouse button stuck.
    func releaseAll() {
        for code in keysDown { key(code, down: false) }
        for button in buttonsDown { mouseButton(button, down: false) }
        keysDown.removeAll()
        buttonsDown.removeAll()
        flags = []
    }

    // MARK: - Mouse

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func moveRelative(dx: Int, dy: Int) {
        let p = cursor
        moveTo(CGPoint(x: p.x + CGFloat(dx), y: p.y + CGFloat(dy)), dx: dx, dy: dy)
    }

    private func moveTo(_ target: CGPoint, dx: Int, dy: Int) {
        let b = CGDisplayBounds(displayID)
        let p = CGPoint(x: min(max(target.x, b.minX), b.maxX - 1), y: min(max(target.y, b.minY), b.maxY - 1))
        let (type, button): (CGEventType, CGMouseButton) =
            buttonsDown.contains(0) ? (.leftMouseDragged, .left)
            : buttonsDown.contains(1) ? (.rightMouseDragged, .right)
            : buttonsDown.contains(2) ? (.otherMouseDragged, .center)
            : (.mouseMoved, .left)
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        // Games that capture the mouse read these raw deltas rather than the cursor position.
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        e.setDoubleValueField(.mouseEventDeltaX, value: Double(dx))
        e.setDoubleValueField(.mouseEventDeltaY, value: Double(dy))
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func mouseButton(_ button: Int, down: Bool) {
        let p = cursor
        let (type, cgButton): (CGEventType, CGMouseButton)
        switch button {
        case 0: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case 1: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        if down { buttonsDown.insert(button) } else { buttonsDown.remove(button) }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton)
        else { return }
        if button == 0 {
            if down {
                let quick = Date().timeIntervalSince(lastClick.time) < 0.35
                    && hypot(p.x - lastClick.location.x, p.y - lastClick.location.y) < 6
                lastClick = (Date(), p, quick ? min(lastClick.count + 1, 3) : 1)
            }
            e.setIntegerValueField(.mouseEventClickState, value: Int64(lastClick.count))
        }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    private func scroll(dx: Int32, dy: Int32) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    private static let modifierFlags: [UInt16: CGEventFlags] = [
        0x38: .maskShift, 0x3C: .maskShift,
        0x3B: .maskControl, 0x3E: .maskControl,
        0x3A: .maskAlternate, 0x3D: .maskAlternate,
        0x37: .maskCommand, 0x36: .maskCommand,
        0x3F: .maskSecondaryFn,
    ]

    private func key(_ code: UInt16, down: Bool) {
        if down { keysDown.insert(code) } else { keysDown.remove(code) }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if let mask = Self.modifierFlags[code] {
            if down { flags.insert(mask) } else if !keysDown.contains(where: { Self.modifierFlags[$0] == mask }) {
                flags.remove(mask)
            }
            e.type = .flagsChanged
        }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }

    /// Types arbitrary text (dictation, emoji, any language) regardless of keyboard layout.
    private func typeText(_ text: String) {
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            i += chunk.count
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                e.post(tap: .cghidEventTap)
            }
        }
    }
}
