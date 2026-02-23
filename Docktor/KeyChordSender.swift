import AppKit
import ApplicationServices

enum KeyChordSender {
    /// Posts a key chord in a way that is closer to real keyboard input:
    /// modifier key down events -> key down/up -> modifier key up events.
    ///
    /// Returns true if events were created and posted.
    static func post(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        tap: CGEventTapLocation = .cghidEventTap,
        sourceState: CGEventSourceStateID = .combinedSessionState
    ) -> Bool {
        guard let source = CGEventSource(stateID: sourceState) else {
            Logger.log("KeyChordSender: Failed to create CGEventSource")
            return false
        }

        let modifiers = modifierKeyEvents(for: flags)
        var currentFlags = CGEventFlags()
        for m in modifiers {
            currentFlags.insert(m.flag)
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: m.keyCode, keyDown: true) else { continue }
            ev.flags = currentFlags
            ev.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
            ev.post(tap: tap)
        }

        // Give the system a moment to observe modifier state.
        if !modifiers.isEmpty {
            usleep(8_000)
        }

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            Logger.log("KeyChordSender: Failed to create key events")
            return false
        }

        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
        up.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
        down.post(tap: tap)
        usleep(20_000)
        up.post(tap: tap)

        for m in modifiers.reversed() {
            guard let ev = CGEvent(keyboardEventSource: source, virtualKey: m.keyCode, keyDown: false) else { continue }
            ev.flags = currentFlags
            ev.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
            ev.post(tap: tap)
            currentFlags.remove(m.flag)
        }

        return true
    }

    /// Posts only the key down/up with modifier flags, without explicit modifier key events.
    /// This tends to work better for system-level shortcuts handled by the hotkey manager.
    static func postSimple(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        tap: CGEventTapLocation = .cgSessionEventTap,
        sourceState: CGEventSourceStateID = .combinedSessionState
    ) -> Bool {
        guard let source = CGEventSource(stateID: sourceState) else {
            Logger.log("KeyChordSender: Failed to create CGEventSource")
            return false
        }

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            Logger.log("KeyChordSender: Failed to create key events")
            return false
        }

        down.flags = flags
        up.flags = flags
        down.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
        up.setIntegerValueField(.eventSourceUserData, value: 0xD0C0A11)
        down.post(tap: tap)
        usleep(20_000)
        up.post(tap: tap)
        return true
    }

    private struct ModifierEvent {
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    private static func modifierKeyEvents(for flags: CGEventFlags) -> [ModifierEvent] {
        var out: [ModifierEvent] = []
        if flags.contains(.maskShift) { out.append(ModifierEvent(keyCode: 56, flag: .maskShift)) }      // left shift
        if flags.contains(.maskControl) { out.append(ModifierEvent(keyCode: 59, flag: .maskControl)) }  // left control
        if flags.contains(.maskAlternate) { out.append(ModifierEvent(keyCode: 58, flag: .maskAlternate)) } // left option
        if flags.contains(.maskCommand) { out.append(ModifierEvent(keyCode: 55, flag: .maskCommand)) }  // left command
        return out
    }
}
