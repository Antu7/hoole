import AVFoundation
import CEngine

/// Mic → 16 kHz mono floats → live speech recognition.
/// Every engine call runs on `queue`: the engine is process-global and not thread-safe.
final class Transcriber {
    /// Main thread. Committed text so far, plus the unconfirmed tail.
    var onUpdate: ((_ committed: String, _ pending: String) -> Void)?
    /// Main thread. Words the engine just confirmed; they never change after this.
    var onCommit: ((String) -> Void)?
    /// Audio thread. RMS of each mic buffer.
    var onLevel: ((Float) -> Void)?

    private var session: AVCaptureSession?
    private let audioQueue = DispatchQueue(label: "hoole.audio") // mic callbacks, and starting/stopping the mic
    private lazy var tap = SampleTap { [weak self] in self?.handle($0) }
    private let queue = DispatchQueue(label: "hoole.engine")
    private let outCapacity: Int32 = 1 << 18
    private lazy var out = UnsafeMutablePointer<CChar>.allocate(capacity: Int(outCapacity)) // ponytail: lives as long as the app

    // Only touched on `queue`.
    private var buffered: [Float] = []
    private var recording: [Float] = [] // the whole dictation at 16 kHz, for Whisper
    private var committed: [String] = []
    private var language: String?
    private var peak: Float = 0 // loudest sample this dictation; 0 means the mic sent pure silence

    func load(_ done: @escaping (String?) -> Void) {
        queue.async {
            var error: String?
            if let url = Bundle.main.url(forResource: "model", withExtension: "cact"),
               let data = try? Data(contentsOf: url) {
                let code = data.withUnsafeBytes { needle_load($0.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count)) }
                if code < 0 { error = String(cString: needle_last_error()) }
            } else {
                error = "The speech model is missing from the app bundle. Rebuild with scripts/build.sh."
            }
            DispatchQueue.main.async { done(error) }
        }
    }

    /// `micUID` picks an input device; nil, or one that's unplugged, uses the system default.
    /// The mic starts on a background queue: if an audio driver misbehaves, recording stalls but the app never freezes.
    func start(language: String?, micUID: String?) throws {
        queue.sync {
            self.language = language
            buffered = []
            recording = []
            committed = []
            peak = 0
        }
        guard let device = micUID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "Hoole", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone found"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        // The capture pipeline converts for us, to what the speech engines expect: 16 kHz mono float.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(tap, queue: audioQueue)
        let session = AVCaptureSession()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw NSError(domain: "Hoole", code: 2, userInfo: [NSLocalizedDescriptionKey: "Can't record from \(device.localizedName)"])
        }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        audioQueue.async { session.startRunning() }
    }

    /// `done` gets the text, whether the mic was completely silent, the whole recording (empty if no speech),
    /// and whether it was too quiet to tell speech from background noise.
    func stop(_ done: @escaping (String, Bool, [Float], Bool) -> Void) {
        let session = self.session
        self.session = nil
        audioQueue.async {
            session?.stopRunning()
            // A second hop, so any buffer delivered while stopping is handed over first.
            self.audioQueue.async {
                self.queue.async {
                    if !self.buffered.isEmpty { self.process() }
                    self.apply(self.call { needle_stream_transcribe_stop($0, $1) })
                    let text = self.committed.joined(separator: " ")
                    let silent = self.peak == 0
                    let heard = hearing(self.recording)
                    let audio = heard == .speech ? normalized(self.recording) : []
                    DispatchQueue.main.async { done(text, silent, audio, heard == .tooQuiet) }
                }
            }
        }
    }

    private func handle(_ samples: [Float]) {
        onLevel?(sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)))
        queue.async {
            self.peak = max(self.peak, samples.lazy.map(abs).max() ?? 0)
            self.buffered += samples
            self.recording += samples
            if self.buffered.count >= 16000 { self.process() } // ~1 s per pass, as the engine expects
        }
    }

    private func process() {
        let chunk = buffered
        buffered = []
        let result = call { out, cap in
            chunk.withUnsafeBufferPointer { pcm in
                withOptionalCString(language) { lang in
                    needle_stream_transcribe_process(pcm.baseAddress, Int32(pcm.count), lang, nil, out, cap)
                }
            }
        }
        apply(result)
    }

    private func apply(_ result: [String: Any]?) {
        guard let result else { return }
        if let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            committed.append(text)
            DispatchQueue.main.async { self.onCommit?(text) }
        }
        let pending = (result["pending"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let text = committed.joined(separator: " ")
        DispatchQueue.main.async { self.onUpdate?(text, pending) }
    }

    private func call(_ body: (UnsafeMutablePointer<CChar>, Int32) -> Int32) -> [String: Any]? {
        guard body(out, outCapacity) >= 0 else {
            NSLog("Speech engine: %@", String(cString: needle_last_error()))
            return nil
        }
        return try? JSONSerialization.jsonObject(with: Data(String(cString: out).utf8)) as? [String: Any]
    }
}

private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    guard let string else { return body(nil) }
    return string.withCString(body)
}

struct InputDevice: Hashable {
    let uid: String
    let name: String
}

/// Microphones the system can record from.
func inputDevices() -> [InputDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
        .devices.map { InputDevice(uid: $0.uniqueID, name: $0.localizedName) }
}

/// Copies each captured buffer's samples out (already 16 kHz mono float, per `audioSettings`).
private final class SampleTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let onSamples: ([Float]) -> Void
    init(_ onSamples: @escaping ([Float]) -> Void) { self.onSamples = onSamples }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
        guard !samples.isEmpty else { return }
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: samples.count * MemoryLayout<Float>.size, destination: &samples)
        onSamples(samples)
    }
}

enum Hearing { case speech, noSpeech, tooQuiet }

/// A loudness check before Whisper. Telling speech from noise is the VAD model's job (see Whisper.vadURL);
/// this only catches recordings too short, or so quiet that nothing in them could be a voice, to say so in the pill.
func hearing(_ samples: [Float]) -> Hearing {
    let frame = 1600 // 100 ms at 16 kHz
    guard samples.count >= frame * 3 else { return .noSpeech }
    let loudest = stride(from: 0, to: samples.count - frame, by: frame).map { start in
        sqrt(samples[start..<start + frame].reduce(0) { $0 + $1 * $1 } / Float(frame))
    }.max() ?? 0
    return loudest < 0.005 ? .tooQuiet : .speech
}

/// Brings a soft recording up to a normal level (peak ≈ 0.5, at most 20× louder), so Whisper hears quiet voices clearly.
func normalized(_ samples: [Float]) -> [Float] {
    let peak = samples.lazy.map(abs).max() ?? 0
    guard peak > 0, peak < 0.5 else { return samples }
    let gain = min(20, 0.5 / peak)
    return samples.map { $0 * gain }
}
