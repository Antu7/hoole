import AppKit

/// Any keys held together: one key ("F5"), modifiers + key ("⌥ + Space"), several keys ("A + Space"), or modifiers alone ("fn").
struct Shortcut: Codable, Equatable {
    var keys: Set<Int64> // virtual key codes, right-hand modifiers folded onto the left ones
    var display: String

    static let optionSpace = Shortcut(keys: [58, 49], display: "⌥ + Space")

    /// True when a key in it would normally type something and no ⌘⌥⌃fn guards it, or it's ⇧ alone (every capital letter).
    var blocksTyping: Bool {
        keys == [56] || keys.isDisjoint(with: [55, 58, 59, 63]) && keys.contains { !modifierKeys.contains($0) && !functionKeys.contains($0) }
    }
}

let modifierKeys: Set<Int64> = [59, 58, 56, 55, 63] // ⌃ ⌥ ⇧ ⌘ fn
private let functionKeys: Set<Int64> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
private let leftHand: [Int64: Int64] = [54: 55, 61: 58, 62: 59, 60: 56]
private let modifierFlag: [Int64: CGEventFlags] = [55: .maskCommand, 58: .maskAlternate, 59: .maskControl, 56: .maskShift, 63: .maskSecondaryFn]
private let keyNames: [Int64: String] = [
    59: "⌃", 58: "⌥", 56: "⇧", 55: "⌘", 63: "fn",
    49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "⌦", 53: "Esc", 123: "←", 124: "→", 125: "↓", 126: "↑",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
    103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
]

/// Marks key events Hoole posts itself (typed text, erasures) so the watcher ignores them.
let syntheticMarker: Int64 = 0x484F4F4C

/// Watches the keyboard with a CGEvent tap on its own thread, so a busy main thread can't stall anyone's typing.
/// Needs Accessibility permission; keeps retrying until it's granted.
final class KeyWatcher {
    var onPress: (() -> Void)?   // main thread
    var onRelease: (() -> Void)?

    var shortcut: Shortcut {
        get { lock.withLock { _shortcut } }
        set { lock.withLock { _shortcut = newValue } }
    }

    private let lock = NSLock()
    private var _shortcut = Shortcut.optionSpace
    private var _onRecorded: ((Shortcut?) -> Void)?  // non-nil while recording a new shortcut

    // Tap thread only.
    private var tap: CFMachPort?
    private var held: [Int64] = []          // in press order
    private var active = false
    private var swallowedKey: Int64?        // the key-down we ate when the shortcut fired; eat its key-up too
    private var wasRecording = false
    private var recorded: [Int64] = []
    private var recordedEvents: [Int64: CGEvent] = [:] // to name character keys later, on main

    func start() {
        Thread { [self] in
            let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) { $0 | 1 << $1.rawValue }
            while true {
                if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                               eventsOfInterest: mask, callback: { _, type, event, info in
                                                   Unmanaged<KeyWatcher>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
                                               }, userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                    self.tap = tap
                    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
                    CGEvent.tapEnable(tap: tap, enable: true)
                    CFRunLoopRun()
                }
                Thread.sleep(forTimeInterval: 2) // no Accessibility permission yet
            }
        }.start()
    }

    /// Captures the next keys held together; `done` gets the shortcut on release, or nil if Esc cancelled.
    func record(_ done: @escaping (Shortcut?) -> Void) {
        lock.withLock { _onRecorded = done }
    }

    func cancelRecording() {
        lock.withLock { _onRecorded = nil }
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        if event.getIntegerValueField(.eventSourceUserData) == syntheticMarker { return pass }

        var code = event.getIntegerValueField(.keyboardEventKeycode)
        code = leftHand[code] ?? code
        let isDown: Bool
        switch type {
        case .keyDown: isDown = true
        case .keyUp: isDown = false
        case .flagsChanged:
            guard let flag = modifierFlag[code] else { return pass } // caps lock and friends
            isDown = event.flags.contains(flag)
        default: return pass
        }
        if isDown { if !held.contains(code) { held.append(code) } } else { held.removeAll { $0 == code } }

        let (shortcut, onRecorded) = lock.withLock { (_shortcut, _onRecorded) }
        if let onRecorded {
            if !wasRecording { wasRecording = true; recorded = []; recordedEvents = [:]; held = isDown ? [code] : [] }
            return record(code, isDown, event, onRecorded)
        }
        wasRecording = false

        if active {
            if !isDown && shortcut.keys.contains(code) {
                active = false
                DispatchQueue.main.async { self.onRelease?() }
            }
            // Eat the shortcut's key repeats, and the key-up of the key-down we ate.
            if type == .keyDown && shortcut.keys.contains(code) { return nil }
            if type == .keyUp && code == swallowedKey { swallowedKey = nil; return nil }
            return pass
        }
        let isRepeat = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard isDown, !isRepeat, Set(held) == shortcut.keys else { return pass }

        active = true
        // Earlier keys of a chord like "A + Space" already typed their character; take it back.
        let typedAlready = shortcut.keys.filter { !modifierKeys.contains($0) && $0 != code }.count
        if typedAlready > 0 { erase(typedAlready) }
        DispatchQueue.main.async { self.onPress?() }
        if type == .flagsChanged { return pass }
        swallowedKey = code
        return nil
    }

    private func record(_ code: Int64, _ isDown: Bool, _ event: CGEvent, _ done: @escaping (Shortcut?) -> Void) -> Unmanaged<CGEvent>? {
        if isDown {
            if code == 53 && recorded.isEmpty { // Esc on its own cancels
                finishRecording(nil, done) { "" }
                return nil
            }
            if !recorded.contains(code) && recorded.count < 4 {
                recorded.append(code)
                if keyNames[code] == nil { recordedEvents[code] = event.copy() }
            }
        } else if held.isEmpty && !recorded.isEmpty {
            let ordered = [59, 58, 56, 55, 63].filter(recorded.contains) + recorded.filter { !modifierKeys.contains($0) }
            let events = recordedEvents
            finishRecording(Set(recorded), done) {
                // Keyboard-layout lookups must run on main (off main, AppKit traps).
                let display = ordered.map { code in
                    keyNames[code] ?? events[code].flatMap { NSEvent(cgEvent: $0)?.characters(byApplyingModifiers: [])?.uppercased() } ?? "Key \(code)"
                }.joined(separator: " + ")
                return display
            }
        }
        return nil // nothing reaches other apps while recording
    }

    private func finishRecording(_ keys: Set<Int64>?, _ done: @escaping (Shortcut?) -> Void, display: @escaping () -> String) {
        lock.withLock { _onRecorded = nil }
        wasRecording = false
        held = []
        DispatchQueue.main.async { done(keys.map { Shortcut(keys: $0, display: display()) }) }
    }
}

/// Posts Delete `count` times.
private func erase(_ count: Int) {
    let source = CGEventSource(stateID: .privateState)
    for _ in 0..<count {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: down)
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event?.post(tap: .cghidEventTap)
        }
    }
}
