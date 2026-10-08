import AppKit
import AVFoundation
import SwiftUI

@main
struct HooleApp: App {
    @State private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environment(state)
        } label: {
            Image(systemName: state.phase == .recording ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

struct Entry: Codable, Identifiable {
    var id = UUID()
    var text: String
    var date = Date()
}

let languages: [(code: String, name: String)] = [
    ("", "Auto-detect"), ("en", "English"), ("de", "German"), ("fr", "French"),
    ("es", "Spanish"), ("it", "Italian"), ("nl", "Dutch"), ("pl", "Polish"),
]

@Observable
final class AppState {
    static let shared = AppState()

    enum Phase { case loading, ready, recording, finishing }

    var phase = Phase.loading
    var error: String?
    var committed = ""
    var pending = ""
    var levels = [Float](repeating: 0, count: 28)
    /// Shown in the floating pill right after a dictation ends.
    var flash: String?
    var history: [Entry] = load("history") ?? [] { didSet { save(history, "history") } }
    var language = UserDefaults.standard.string(forKey: "language") ?? "en" {
        didSet { UserDefaults.standard.set(language, forKey: "language") }
    }
    var autoType = UserDefaults.standard.object(forKey: "autoType") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoType, forKey: "autoType")
            if autoType { requestAccessibility() }
        }
    }
    /// Input device UID; empty follows the system default.
    var micUID = UserDefaults.standard.string(forKey: "micUID") ?? "" {
        didSet { UserDefaults.standard.set(micUID, forKey: "micUID") }
    }
    var shortcut: Shortcut = load("shortcut") ?? .fn {
        didSet { save(shortcut, "shortcut"); keys.shortcut = shortcut }
    }

    private let transcriber = Transcriber()
    private let hud = HUD()
    let keys = KeyWatcher()
    private var typing = false     // typing into another app for this dictation
    private var typedAnything = false   // next words need a leading space
    private var target: pid_t?           // app this dictation types into
    private var lastTarget: pid_t?       // app the previous dictation typed into

    private init() {
        transcriber.onUpdate = { [weak self] committed, pending in
            guard let self, self.phase == .recording || self.phase == .finishing else { return }
            self.committed = committed
            self.pending = pending
        }
        transcriber.onCommit = { [weak self] words in
            guard let self, self.typing else { return }
            type((self.typedAnything ? " " : "") + words)
            self.typedAnything = true
        }
        transcriber.onLevel = { [weak self] rms in
            // -50 dB … 0 dB → 0 … 1
            let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 50))
            DispatchQueue.main.async {
                guard let self, self.phase == .recording else { return }
                self.levels.removeFirst()
                self.levels.append(level)
            }
        }
        transcriber.load { [weak self] error in
            self?.error = error
            self?.phase = error == nil ? .ready : .loading
        }
        keys.shortcut = shortcut
        // Push to talk: listen while the shortcut is held.
        keys.onPress = { [weak self] in if self?.phase == .ready { self?.start() } }
        keys.onRelease = { [weak self] in if self?.phase == .recording { self?.stop() } }
        keys.start()
    }

    func toggle() {
        switch phase {
        case .ready: start()
        case .recording: stop()
        case .loading, .finishing: break
        }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in } // the key is long released by the time they answer
            return
        default:
            error = "Microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            return
        }
        do {
            committed = ""
            pending = ""
            flash = nil
            error = nil
            levels = levels.map { _ in 0 }
            // Type live only when another app has the cursor (not our own popover).
            target = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if autoType && !AXIsProcessTrusted() { requestAccessibility() }
            typing = autoType && AXIsProcessTrusted() && target != ProcessInfo.processInfo.processIdentifier
            // ponytail: same app as last time → assume the cursor sits right after our text, so continue with a space.
            // Reading the text before the cursor via AX would be exact, but terminals don't expose it.
            typedAnything = typing && target == lastTarget
            try transcriber.start(language: language.isEmpty ? nil : language, micUID: micUID.isEmpty ? nil : micUID)
            phase = .recording
            hud.show()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func stop() {
        phase = .finishing
        levels = levels.map { _ in 0 }
        transcriber.stop { [weak self] text, silent in
            // Every onCommit has already run: they're queued on main ahead of this.
            guard let self else { return }
            self.committed = text
            self.pending = ""
            self.phase = .ready
            if text.isEmpty {
                self.flash = silent ? "No sound from the mic. Pick another in the menu" : "Didn't catch that"
            } else {
                self.history.insert(Entry(text: text), at: 0)
                if self.history.count > 50 { self.history.removeLast(self.history.count - 50) }
                if self.typing {
                    self.flash = "Done"
                } else {
                    copy(text) // nowhere to type, so keep it on the clipboard rather than lose it
                    self.flash = "Copied to clipboard"
                }
            }
            if self.typing && !text.isEmpty { self.lastTarget = self.target }
            self.typing = false
            self.hud.hide(after: 1.2)
        }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Types text at the cursor of the frontmost app as Unicode key events. Needs Accessibility permission.
private func type(_ text: String) {
    // Private state: the shortcut's physically held modifiers (e.g. ⇧) must not leak into the typed text.
    let source = CGEventSource(stateID: .privateState)
    let units = Array(text.utf16)
    var start = 0
    while start < units.count {
        var end = min(start + 20, units.count) // key events carry at most ~20 UTF-16 units
        if end < units.count && UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        let chunk = Array(units[start..<end])
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
            event?.flags = []
            event?.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
            event?.post(tap: .cghidEventTap)
        }
        start = end
    }
}

func requestAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
}

private func load<T: Decodable>(_ key: String) -> T? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}

private func save<T: Encodable>(_ value: T, _ key: String) {
    UserDefaults.standard.set(try? JSONEncoder().encode(value), forKey: key)
}
