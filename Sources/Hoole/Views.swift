import AppKit
import AVFoundation
import SwiftUI

// Warm paper palette: solid cream, ink, and one terracotta accent. Always light, never translucent.
private let paper = Color(red: 0.953, green: 0.933, blue: 0.894)      // #F3EEE4
private let sand = Color(red: 0.902, green: 0.875, blue: 0.824)       // #E6DFD2
private let ink = Color(red: 0.169, green: 0.153, blue: 0.133)        // #2B2722
private let terracotta = Color(red: 0.769, green: 0.333, blue: 0.227) // #C4553A
private let olive = Color(red: 0.42, green: 0.53, blue: 0.35)         // ready

// MARK: - Menu bar popover

struct PopoverView: View {
    @Environment(AppState.self) private var state
    @State private var mics: [InputDevice] = []

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 16) {
            header
            RecordButton()
            TranscriptCard()
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(terracotta)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PermissionsBanner()
            if !state.history.isEmpty { HistoryList() }
            Rectangle().fill(ink.opacity(0.10)).frame(height: 1)
            VStack(spacing: 10) {
                HStack {
                    Label("Shortcut", systemImage: "keyboard").foregroundStyle(ink.opacity(0.6))
                    Spacer()
                    ShortcutRecorder()
                }
                if state.shortcut.blocksTyping {
                    Text("While Hoole runs, \(state.shortcut.display) won't type normally.")
                        .font(.caption2)
                        .foregroundStyle(terracotta)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack {
                    Label("Microphone", systemImage: "mic").foregroundStyle(ink.opacity(0.6))
                    Spacer()
                    Picker("", selection: $state.micUID) {
                        Text("System default").tag("")
                        ForEach(mics, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Label("Language", systemImage: "globe").foregroundStyle(ink.opacity(0.6))
                    Spacer()
                    Picker("", selection: $state.language) {
                        ForEach(languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Label("Type where my cursor is", systemImage: "text.cursor").foregroundStyle(ink.opacity(0.6))
                    Spacer()
                    Toggle("", isOn: $state.autoType)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            .font(.callout)
            HStack {
                CreditLink()
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.55))
                    .keyboardShortcut("q")
            }
        }
        .padding(18)
        .frame(width: 360)
        .foregroundStyle(ink)
        .background(paper)
        .tint(terracotta)
        .environment(\.colorScheme, .light)
        .onAppear { mics = inputDevices() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HooleMark(size: 26)
            Text("Hoole").font(.system(size: 19, weight: .semibold, design: .serif))
            Spacer()
            StatusPill(phase: state.phase)
        }
    }
}

/// "Built by …", linking to the author's GitHub; underlines on hover.
/// The app icon in miniature: a paper tile with an ink waveform and a terracotta dot.
struct HooleMark: View {
    var size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.965, blue: 0.93), sand], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(ink.opacity(0.14), lineWidth: 0.5))
            .overlay {
                HStack(spacing: size * 0.07) {
                    ForEach([0.36, 0.7, 1.0, 0.58, 0.3], id: \.self) { h in
                        Capsule().fill(ink).frame(width: size * 0.08, height: size * 0.5 * h)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Circle().fill(terracotta).frame(width: size * 0.13).padding(size * 0.15)
            }
            .frame(width: size, height: size)
    }
}

struct CreditLink: View {
    @State private var hovering = false

    var body: some View {
        Link(destination: URL(string: "https://github.com/antu7")!) {
            Text("Built by Tanvir Hossain Antu")
                .font(.caption2)
                .underline(hovering)
                .foregroundStyle(hovering ? AnyShapeStyle(terracotta) : AnyShapeStyle(ink.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hovering = inside
            inside ? NSCursor.pointingHand.push() : NSCursor.pop()
        }
        .help("github.com/antu7")
    }
}

struct StatusPill: View {
    let phase: AppState.Phase

    var body: some View {
        let (text, color): (String, Color) = switch phase {
        case .loading: ("Loading", .gray)
        case .ready: ("Ready", olive)
        case .recording: ("Listening", terracotta)
        case .finishing: ("Transcribing", terracotta.opacity(0.6))
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: color.opacity(0.8), radius: phase == .recording ? 3 : 0)
            Text(text.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(ink.opacity(0.6))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(sand))
        .animation(.default, value: text)
    }
}

struct RecordButton: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let recording = state.phase == .recording
        let level = CGFloat(state.levels.last ?? 0)
        VStack(spacing: 10) {
            Button { state.toggle() } label: {
                ZStack {
                    // Level rings: hairlines that breathe with your voice, only while on air.
                    ForEach(0..<2) { i in
                        Circle().strokeBorder(terracotta.opacity(recording ? 0.45 - Double(i) * 0.2 : 0), lineWidth: 1)
                            .frame(width: 96 + CGFloat(i) * 20, height: 96 + CGFloat(i) * 20)
                            .scaleEffect(recording ? 1 + level * (0.10 + CGFloat(i) * 0.08) : 0.9)
                    }
                    // The button: a raised paper disc with a terracotta mic; solid terracotta while listening.
                    Circle()
                        .fill(recording ? AnyShapeStyle(terracotta) : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.99, green: 0.98, blue: 0.955), Color(red: 0.94, green: 0.915, blue: 0.87)], startPoint: .top, endPoint: .bottom)))
                        .overlay(Circle().strokeBorder(recording ? terracotta : ink.opacity(0.12), lineWidth: 1))
                        .frame(width: 76, height: 76)
                        .shadow(color: recording ? terracotta.opacity(0.35) : ink.opacity(0.14), radius: recording ? 12 : 4, y: recording ? 0 : 2)
                    if state.phase == .loading || state.phase == .finishing {
                        ProgressView().controlSize(.small).tint(terracotta)
                    } else {
                        Image(systemName: recording ? "stop.fill" : "mic.fill")
                            .font(.system(size: recording ? 22 : 26, weight: .medium))
                            .foregroundStyle(recording ? paper : terracotta)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 136, height: 136)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: level)
                .animation(.spring(duration: 0.3), value: recording)
            }
            .buttonStyle(.plain)
            .disabled(state.phase == .loading || state.phase == .finishing)

            HStack(spacing: 4) {
                Text(recording ? "Listening while you hold" : "Hold")
                KeyCap(state.shortcut.display)
                if !recording { Text("and talk, let go to stop") }
            }
            .font(.caption)
            .foregroundStyle(ink.opacity(0.6))
        }
    }
}

struct KeyCap: View {
    let key: String
    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(ink.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(red: 0.99, green: 0.98, blue: 0.96)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(ink.opacity(0.16), lineWidth: 0.5))
            .shadow(color: ink.opacity(0.22), radius: 0, y: 1) // the key's lower edge
    }
}

/// Click, then hold any key or keys together and let go. Esc cancels.
struct ShortcutRecorder: View {
    @Environment(AppState.self) private var state
    @State private var listening = false

    var body: some View {
        Button { listening ? cancel() : begin() } label: {
            Text(listening ? "Press keys…" : state.shortcut.display)
                .font(.callout.weight(.medium))
                .frame(minWidth: 84)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(listening ? AnyShapeStyle(terracotta.opacity(0.12)) : AnyShapeStyle(sand)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(listening ? AnyShapeStyle(terracotta) : AnyShapeStyle(.clear)))
        }
        .buttonStyle(.plain)
        .help("Click, then press one key or several together, and let go. Esc cancels.")
        .onDisappear { cancel() }
    }

    private func begin() {
        guard AXIsProcessTrusted() else { requestAccessibility(); return }
        listening = true
        state.keys.record { shortcut in
            listening = false
            if let shortcut { state.shortcut = shortcut }
        }
    }

    private func cancel() {
        guard listening else { return }
        state.keys.cancelRecording()
        listening = false
    }
}

/// Lists whichever permissions are still missing, each with a one-click fix. Hidden once all are granted.
struct PermissionsBanner: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Neither permission posts a change notification, so re-check while the popover is open.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let mic = AVCaptureDevice.authorizationStatus(for: .audio)
            let needsMic = mic != .authorized
            let needsAX = !AXIsProcessTrusted() // the shortcut needs it too
            if needsMic || needsAX {
                VStack(spacing: 8) {
                    if needsMic {
                        row("mic.fill", "Microphone, so Hoole can hear you") {
                            if mic == .notDetermined {
                                AVCaptureDevice.requestAccess(for: .audio) { _ in }
                            } else {
                                openSettings("Privacy_Microphone")
                            }
                        }
                    }
                    if needsAX {
                        row("keyboard.fill", "Accessibility, for your shortcut and typing") {
                            requestAccessibility()
                            openSettings("Privacy_Accessibility")
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(terracotta.opacity(0.10)))
            }
        }
    }

    private func row(_ icon: String, _ text: String, fix: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(terracotta).frame(width: 16)
            Text(text).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Button("Allow", action: fix).controlSize(.small)
        }
    }

    private func openSettings(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

struct TranscriptCard: View {
    @Environment(AppState.self) private var state
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if state.committed.isEmpty && state.pending.isEmpty {
                    Text(state.phase == .recording ? "Listening…" : "Your words will appear here.")
                        .foregroundStyle(ink.opacity(0.35))
                } else {
                    Text("\(state.committed) \(Text(state.pending).foregroundStyle(ink.opacity(0.45)))")
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 14, design: .serif))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if !state.committed.isEmpty && state.phase == .ready {
                HStack {
                    Spacer()
                    Button {
                        copy(state.committed)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(red: 0.98, green: 0.97, blue: 0.945)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(state.phase == .recording ? terracotta.opacity(0.6) : ink.opacity(0.10), lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: state.committed)
    }
}

struct HistoryList: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT").font(.system(size: 9.5, weight: .semibold)).tracking(0.8).foregroundStyle(ink.opacity(0.45))
                Spacer()
                Button("Clear") { state.history.removeAll() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(ink.opacity(0.5))
            }
            // ponytail: last 3 only; a full history window if people want to search old dictations
            VStack(spacing: 2) {
                ForEach(state.history.prefix(3)) { HistoryRow(entry: $0) }
            }
        }
    }
}

struct HistoryRow: View {
    let entry: Entry
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        Button {
            copy(entry.text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                    Text(entry.date, style: .relative).font(.caption2).foregroundStyle(ink.opacity(0.4))
                }
                Spacer(minLength: 0)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? olive : ink.opacity(0.5))
                    .opacity(hovering || copied ? 1 : 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? sand.opacity(0.7) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

// MARK: - Floating pill

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(ink.opacity(0.25 + Double(levels[i]) * 0.65))
                    .frame(width: 2.5, height: max(3, CGFloat(levels[i]) * 24))
            }
        }
        .animation(.easeOut(duration: 0.1), value: levels)
    }
}

struct HUDView: View {
    @Environment(AppState.self) private var state
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch state.phase {
                case .recording:
                    Circle().fill(terracotta).frame(width: 8, height: 8)
                        .shadow(color: terracotta.opacity(0.6), radius: pulse ? 4 : 0)
                        .opacity(pulse ? 1 : 0.65)
                        .animation(.easeInOut(duration: 0.9).repeatForever(), value: pulse)
                        .onAppear { pulse = true }
                case .finishing:
                    ProgressView().controlSize(.small).tint(terracotta)
                default:
                    Image(systemName: ok ? "checkmark.circle.fill" : "ear.trianglebadge.exclamationmark")
                        .foregroundStyle(ok ? olive : terracotta)
                }
            }
            .frame(width: 18)

            if state.phase == .recording {
                Waveform(levels: Array(state.levels.suffix(16)))
                    .frame(height: 26)
            }

            Text(message)
                .font(.system(size: 13, weight: .regular))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 280, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(paper))
        .overlay(Capsule().strokeBorder(ink.opacity(0.12), lineWidth: 0.75))
        .shadow(color: ink.opacity(0.22), radius: 16, y: 6)
        .foregroundStyle(ink)
        .environment(\.colorScheme, .light)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(duration: 0.3), value: state.phase)
    }

    private var ok: Bool { state.flash == "Done" || state.flash == "Copied to clipboard" }

    private var message: String {
        switch state.phase {
        case .recording:
            let text = [state.committed, state.pending].filter { !$0.isEmpty }.joined(separator: " ")
            return text.isEmpty ? "Listening…" : text
        case .finishing: return "Transcribing…"
        default: return state.flash ?? ""
        }
    }
}

/// A click-through panel at the bottom of the screen that never takes focus,
/// so the app you're dictating into stays active.
final class HUD {
    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 90),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView().environment(AppState.shared))
        return panel
    }()
    private var hideWork: DispatchWorkItem?

    func show() {
        hideWork?.cancel()
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 60))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval) {
        let work = DispatchWorkItem { [panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
