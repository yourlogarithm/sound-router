// SoundRouter: menu-bar app that plays an input device (e.g. HC-V9 capture card) live on the default output.
// Build: ./build.sh            Test: SoundRouter.app/Contents/MacOS/SoundRouter --test
// Tune:  defaults write local.soundrouter latencyMs 10   (lower = less delay, more dropouts; default 20)
import AVFoundation
import CoreAudio
import ServiceManagement
import SwiftUI
import Synchronization

/// Single-producer/single-consumer ring between the capture and playback engines (separate clocks).
final class Ring: @unchecked Sendable {
    let channels: Int, capacity: Int, target: Int, maxFill: Int
    private let data: [UnsafeMutablePointer<Float>]
    private let written = Atomic<Int>(0)  // total frames written, writer-owned
    private let consumed = Atomic<Int>(0) // total frames read, reader-owned
    private var primed = false            // reader-only

    init(channels: Int, capacity: Int, target: Int) {
        self.channels = channels; self.capacity = capacity; self.target = target
        maxFill = target * 3
        data = (0..<channels).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return p
        }
    }

    deinit { data.forEach { $0.deallocate() } }

    /// Realtime input thread.
    func write(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let w = written.load(ordering: .relaxed)
        // ponytail: overflow drops newest frames; only happens if playback stalls ~1s
        let n = min(frames, capacity - (w - consumed.load(ordering: .acquiring)))
        for ch in 0..<min(channels, abl.count) {
            guard let src = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<n { data[ch][(w + i) % capacity] = src[i] }
        }
        written.store(w + n, ordering: .releasing)
    }

    /// Realtime output thread.
    func read(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let w = written.load(ordering: .acquiring)
        var r = consumed.load(ordering: .relaxed)
        // ponytail: drift/hiccup handled by jumping (tiny click), resample if clicks ever get audible
        if w - r > maxFill { r = w - target }
        let avail = w - r
        if !primed && avail >= target { primed = true }
        let n = primed ? min(frames, avail) : 0
        if n < frames { primed = false } // underrun: re-buffer up to target before playing again
        for ch in 0..<abl.count {
            guard let dst = abl[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            let src = data[min(ch, channels - 1)]
            for i in 0..<n { dst[i] = src[(r + i) % capacity] }
            for i in n..<frames { dst[i] = 0 }
        }
        consumed.store(r + n, ordering: .releasing)
    }
}

var devicesAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)

func inputDevices() -> [(id: AudioDeviceID, name: String)] {
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(sys, &devicesAddress, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(sys, &devicesAddress, 0, nil, &size, &ids)
    return ids.compactMap { id in
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                           mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var n: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n)
        guard n > 0 else { return nil } // no input streams
        a.mSelector = kAudioObjectPropertyName; a.mScope = kAudioObjectPropertyScopeGlobal
        var name: Unmanaged<CFString>?
        n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &n, &name) == noErr,
              let s = name?.takeRetainedValue() as String? else { return nil }
        return (id, s)
    }
}

/// Free function on purpose: these blocks run on realtime audio threads, keep them out of any actor.
func makeNodes(_ ring: Ring, _ fmt: AVAudioFormat) -> (AVAudioSinkNode, AVAudioSourceNode) {
    let sink = AVAudioSinkNode { _, frames, abl in
        ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)), frames: Int(frames))
        return noErr
    }
    let source = AVAudioSourceNode(format: fmt) { _, _, frames, abl in
        ring.read(UnsafeMutableAudioBufferListPointer(abl), frames: Int(frames))
        return noErr
    }
    return (sink, source)
}

/// All methods run on the main thread.
final class Router: ObservableObject {
    @Published var devices: [String] = []
    @Published var running = false
    @Published var status = ""
    @Published var deviceName = UserDefaults.standard.string(forKey: "device") ?? "HC-V9 Audio" {
        didSet { UserDefaults.standard.set(deviceName, forKey: "device"); if wanted { start() } }
    }
    /// User's on/off switch; persisted so it resumes after login or re-plugging the dock.
    @Published var wanted = UserDefaults.standard.bool(forKey: "wanted") {
        didSet { UserDefaults.standard.set(wanted, forKey: "wanted"); if wanted { start() } else { stop() } }
    }

    private var inEngine: AVAudioEngine?, outEngine: AVAudioEngine?
    private var sink: AVAudioSinkNode?, source: AVAudioSourceNode?
    private var device: AudioDeviceID = 0, format: AVAudioFormat?
    private var observers: [NSObjectProtocol] = []

    init() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, .main) { [weak self] _, _ in
            self?.refreshDevices()
        }
        refreshDevices()
    }

    func refreshDevices() {
        devices = inputDevices().map(\.name)
        if wanted && !running { start() } // capture card / dock plugged (back) in
    }

    func start() {
        stop()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.start() } }
            return
        default:
            status = "Mic access denied: System Settings › Privacy & Security › Microphone"
            return
        }
        guard let dev = inputDevices().first(where: { $0.name == deviceName })?.id else {
            status = "Waiting for \(deviceName)…"
            return
        }
        let i = AVAudioEngine(), o = AVAudioEngine()
        do { try i.inputNode.auAudioUnit.setDeviceID(dev) } catch { status = "Can't open \(deviceName)"; return }
        let fmt = i.inputNode.inputFormat(forBus: 0) // hardware format; outputFormat stays stale from the default mic
        let ms = UserDefaults.standard.double(forKey: "latencyMs")
        let ring = Ring(channels: Int(fmt.channelCount), capacity: Int(fmt.sampleRate),
                        target: Int(fmt.sampleRate * (ms > 0 ? ms : 20) / 1000))
        let (sink, source) = makeNodes(ring, fmt)
        i.attach(sink); o.attach(source)
        (inEngine, outEngine, self.sink, self.source, device, format) = (i, o, sink, source, dev, fmt)
        // Output switch (AirPods <-> speakers) or input hiccup: reconnect same engines.
        // Rebuilding engines here instead would re-trigger the notification forever.
        observers = [i, o].map {
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: $0, queue: .main) { [weak self] _ in
                self?.reconnect()
            }
        }
        reconnect()
    }

    private func reconnect() {
        guard let i = inEngine, let o = outEngine, let sink, let source, let format else { return }
        i.stop(); o.stop()
        do {
            try i.inputNode.auAudioUnit.setDeviceID(device) // re-pin: a config change could fall back to the built-in mic
            i.connect(i.inputNode, to: sink, format: format)
            o.connect(source, to: o.mainMixerNode, format: format)
            try i.start()
            try o.start()
            running = true
            status = "\(deviceName) · \(Int(format.sampleRate / 1000)) kHz · \(format.channelCount)ch"
        } catch {
            stop()
            status = "Waiting for \(deviceName)…" // unplugged; refreshDevices restarts on re-plug
        }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        inEngine?.stop(); outEngine?.stop()
        (inEngine, outEngine, sink, source, format) = (nil, nil, nil, nil, nil)
        running = false
        status = ""
    }
}

struct RouterApp: App {
    @StateObject var router = Router()

    var body: some Scene {
        MenuBarExtra {
            Toggle("Play input", isOn: $router.wanted)
            if !router.status.isEmpty { Text(router.status) }
            Picker("Input", selection: $router.deviceName) {
                // keep the saved device selectable even while unplugged
                ForEach(router.devices.contains(router.deviceName) ? router.devices : [router.deviceName] + router.devices,
                        id: \.self) { Text($0) }
            }
            Divider()
            Toggle("Launch at login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { try? $0 ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
            Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(systemName: router.running ? "speaker.wave.2.fill" : "speaker.slash")
        }
    }
}

func selfTest() {
    let r = Ring(channels: 1, capacity: 100, target: 10) // maxFill 30
    func buf(_ frames: Int) -> (UnsafeMutableAudioBufferListPointer, UnsafeMutablePointer<Float>) {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let l = AudioBufferList.allocate(maximumBuffers: 1)
        l[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: p)
        return (l, p)
    }
    let (w, wp) = buf(1), (o, op) = buf(8)
    var next: Float = 1
    func feed(_ n: Int) { for _ in 0..<n { wp[0] = next; next += 1; r.write(w, frames: 1) } }

    feed(5); r.read(o, frames: 8)
    precondition(op[0] == 0, "below target -> silence")
    feed(10); r.read(o, frames: 8)
    precondition((0..<8).allSatisfy { op[$0] == Float($0 + 1) }, "primed -> 1...8")
    r.read(o, frames: 8)
    precondition(op[6] == 15 && op[7] == 0, "underrun -> tail silence")
    feed(50); r.read(o, frames: 8)
    precondition(op[0] == 56, "backlog > maxFill -> jump to target latency")
    feed(500); r.read(o, frames: 8) // overflow must not crash or corrupt
    precondition(op[7] == op[0] + 7, "contiguous after overflow")
    print("self-test ok")
}

if CommandLine.arguments.contains("--test") { selfTest(); exit(0) }
RouterApp.main()
