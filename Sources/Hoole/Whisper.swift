import AppKit
import whisper

/// Whisper large-v3-turbo through whisper.cpp, for the Best accuracy mode. Runs on the GPU via Metal.
/// Transcribes a whole recording at once, after the key is released. The model ships inside the app.
final class Whisper {
    static let modelURL = Bundle.main.url(forResource: "whisper-large-v3-turbo", withExtension: "bin")
    static var isAvailable: Bool { modelURL != nil }

    /// Every language Whisper understands (about 99), as (code, English name), sorted by name.
    static let languages: [(code: String, name: String)] = (0...whisper_lang_max_id())
        .map { (String(cString: whisper_lang_str($0)), String(cString: whisper_lang_str_full($0)).capitalized) }
        .sorted { $0.name < $1.name }

    private let queue = DispatchQueue(label: "hoole.whisper")
    private var context: OpaquePointer?

    init() {
        // Free the model before exit: whisper.cpp's GPU teardown aborts if a context is still alive at exit.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [self] _ in
            queue.sync {
                if let context { whisper_free(context) }
                context = nil
            }
        }
    }

    /// Loads the model now (takes a moment), so the first dictation doesn't wait for it.
    func warmUp() {
        queue.async { _ = self.loadedContext() }
    }

    /// `done` runs on main with the text and how long Whisper took, in seconds.
    func transcribe(_ samples: [Float], language: String?, _ done: @escaping (String, TimeInterval) -> Void) {
        queue.async {
            let started = Date()
            var text = ""
            if let context = self.loadedContext(), !samples.isEmpty {
                var params = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
                params.beam_search.beam_size = 5
                params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
                params.print_progress = false
                params.print_realtime = false
                params.print_special = false
                params.print_timestamps = false
                params.no_timestamps = true
                params.translate = false
                params.suppress_nst = true // drop non-speech tokens like "[music]"
                text = (language ?? "auto").withCString { lang in
                    params.language = lang
                    let code = samples.withUnsafeBufferPointer { whisper_full(context, params, $0.baseAddress, Int32($0.count)) }
                    guard code == 0 else { return "" }
                    return (0..<whisper_full_n_segments(context))
                        .map { String(cString: whisper_full_get_segment_text(context, $0)) }
                        .joined()
                }
            }
            let elapsed = Date().timeIntervalSince(started)
            var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // On silence Whisper can return just "-" or "..."; that's not speech, so don't type it.
            if !result.contains(where: { $0.isLetter || $0.isNumber }) { result = "" }
            DispatchQueue.main.async { done(result, elapsed) }
        }
    }

    private func loadedContext() -> OpaquePointer? {
        if context == nil, let url = Self.modelURL {
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            context = whisper_init_from_file_with_params(url.path, params)
        }
        return context
    }
}
