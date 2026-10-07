import AVFoundation
import CoreAudio
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

    private var engine = AVAudioEngine()
    private var peak: Float = 0 // loudest raw sample this dictation; 0 means the mic sent pure silence
    private let queue = DispatchQueue(label: "hoole.engine")
    private let format16k = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let outCapacity: Int32 = 1 << 18
    private lazy var out = UnsafeMutablePointer<CChar>.allocate(capacity: Int(outCapacity)) // ponytail: lives as long as the app

    // Only touched on `queue`.
    private var buffered: [Float] = []
    private var committed: [String] = []
    private var language: String?

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

    /// `micUID` picks an input device; nil follows the system default.
    func start(language: String?, micUID: String?) throws {
        queue.sync {
            self.language = language
            buffered = []
            committed = []
        }
        // A fresh engine each time picks up the current device; a long-lived one can stay bound to a stale input.
        engine = AVAudioEngine()
        peak = 0
        let input = engine.inputNode
        if var device = micUID.flatMap(deviceID(uid:)), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inFormat, to: format16k) else {
            throw NSError(domain: "Hoole", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported microphone format"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, converter)
        }
        engine.prepare()
        try engine.start()
    }

    /// `done` gets the text, and whether the mic was completely silent.
    func stop(_ done: @escaping (String, Bool) -> Void) {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Runs after every chunk the tap already queued.
        queue.async {
            if !self.buffered.isEmpty { self.process() }
            self.apply(self.call { needle_stream_transcribe_stop($0, $1) })
            let text = self.committed.joined(separator: " ")
            let silent = self.peak == 0
            DispatchQueue.main.async { done(text, silent) }
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer, _ converter: AVAudioConverter) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: format16k, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: converted, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        let samples = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
        guard !samples.isEmpty else { return }
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        peak = max(peak, samples.lazy.map(abs).max() ?? 0)
        onLevel?(rms)
        queue.async {
            self.buffered += samples
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

/// Audio devices that can record, as CoreAudio lists them.
func inputDevices() -> [InputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids)
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var count: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &count) == noErr, count > 0,
              let name = stringProperty(id, kAudioObjectPropertyName), !name.hasPrefix("CADefaultDevice"),
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return InputDevice(uid: uid, name: name)
    }
}

private func deviceID(uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = withUnsafePointer(to: &cfUID) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
    }
    return status == noErr && id != 0 ? id : nil // nil when it's unplugged: fall back to the default
}

private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}
