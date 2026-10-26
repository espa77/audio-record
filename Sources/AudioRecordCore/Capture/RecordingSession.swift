import AVFoundation
import Foundation

public struct RecordingResult {
    public let timestamp: String        // YYYY-MM-DD_HH-MM-SS
    public let startedAt: Date
    public let duration: TimeInterval
    public let audioURL: URL            // <root>/<ts>.m4a (stereo: L = mic, R = system)
    public let workDir: URL             // <root>/.inprogress/<ts>/ with mic.caf + sys.caf (lossless)
    public var micTrackURL: URL { workDir.appendingPathComponent("mic.caf") }
    public var sysTrackURL: URL { workDir.appendingPathComponent("sys.caf") }
}

/// One recording: system tap + microphone → two lossless tracks → finalised stereo M4A.
public final class RecordingSession {
    public let settings: Settings
    public let startedAt: Date
    public let timestamp: String
    public let workDir: URL

    private let tap: SystemAudioTap
    private let mic = MicCapture()
    private let micWriter: TrackWriter
    private let sysWriter: TrackWriter
    private var started = false
    private let stateLock = NSLock()
    private let watchdogQueue = DispatchQueue(label: "com.esteiner.audiorecord.watchdog")
    private var watchdog: DispatchSourceTimer?
    private var lastRestartAttempt: [String: Date] = [:]
    /// Capture restarts after a stall (device change, sleep, sample-rate switch).
    public private(set) var restarts = 0
    /// No buffer for this long means the source died; both sources deliver buffers continuously, even silence.
    public static let stallSeconds: TimeInterval = 4
    private lazy var sysHandler: SystemAudioTap.BufferHandler = { [sysWriter] buffer, hostTime in sysWriter.write(buffer, hostTime: hostTime) }
    private lazy var micHandler: MicCapture.BufferHandler = { [micWriter] buffer, hostTime in micWriter.write(buffer, hostTime: hostTime) }

    public init(settings: Settings, excludedPIDs: [pid_t] = []) {
        self.settings = settings
        self.startedAt = Date()
        self.timestamp = Timestamps.fileStamp(startedAt)
        self.workDir = settings.inProgressDir.appendingPathComponent(timestamp, isDirectory: true)
        self.tap = SystemAudioTap(excludedPIDs: excludedPIDs)
        self.micWriter = TrackWriter(url: workDir.appendingPathComponent("mic.caf"))
        self.sysWriter = TrackWriter(url: workDir.appendingPathComponent("sys.caf"))
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }
    public var outputDeviceName: String { tap.outputDeviceName }
    public var micDeviceName: String { mic.deviceName }

    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !started else { return }
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        try tap.start(handler: sysHandler)
        guard let sysFormat = tap.format else { throw AudioRecordError("Tap format unavailable") }
        try sysWriter.open(format: sysFormat)

        do {
            try mic.start(handler: micHandler)
            guard let micFormat = mic.format else { throw AudioRecordError("Mic format unavailable") }
            try micWriter.open(format: micFormat)
        } catch {
            tap.stop(); sysWriter.close()
            throw error
        }
        started = true
        startWatchdog()
        if let s = ProcessInfo.processInfo.environment["AUDIORECORD_TEST_STALL_AFTER"].flatMap(Double.init) {
            // Test hook: kill both captures silently so the watchdog has to recover them.
            watchdogQueue.asyncAfter(deadline: .now() + s) { [weak self] in
                guard let self else { return }
                self.stateLock.lock(); self.tap.stop(); self.mic.stop(); self.stateLock.unlock()
                Log.capture.warning("TEST: capture stopped to simulate a device loss")
            }
        }
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.checkStall() }
        timer.resume()
        watchdog = timer
    }

    /// Restarts a source that stopped delivering buffers. The writer pads the hole with silence,
    /// so the track keeps its wall-clock alignment; a new device format is converted on the fly.
    private func checkStall() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard started else { return }
        let now = Date()
        func stalled(_ w: TrackWriter, _ name: String) -> Bool {
            guard now.timeIntervalSince(w.lastWriteAt ?? startedAt) > Self.stallSeconds else { return false }
            if let last = lastRestartAttempt[name], now.timeIntervalSince(last) < 5 { return false }
            lastRestartAttempt[name] = now
            return true
        }
        if stalled(sysWriter, "system") {
            Log.capture.warning("System audio stalled for \(Self.stallSeconds, privacy: .public)s; restarting the tap")
            tap.stop()
            do { try tap.start(handler: sysHandler); restarts += 1 } catch {
                Log.capture.error("Tap restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if stalled(micWriter, "mic") {
            Log.capture.warning("Microphone stalled for \(Self.stallSeconds, privacy: .public)s; restarting the engine")
            do { try mic.start(handler: micHandler); restarts += 1 } catch {
                Log.capture.error("Mic restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Stops capture and writes `<root>/<ts>.m4a`. Lossless tracks stay in `workDir` for transcription.
    public func stop() throws -> RecordingResult {
        watchdog?.cancel(); watchdog = nil
        stateLock.lock(); defer { stateLock.unlock() }
        guard started else { throw AudioRecordError("Session not started") }
        started = false
        mic.stop()
        tap.stop()
        micWriter.close()
        sysWriter.close()
        let duration = max(micWriter.seconds, sysWriter.seconds)

        // Align the two tracks on the shared host clock: the later starter gets leading silence.
        let micStart = HostClock.seconds(micWriter.firstHostTime ?? 0)
        let sysStart = HostClock.seconds(sysWriter.firstHostTime ?? 0)
        let origin = min(micStart, sysStart)
        let micLeadIn = micWriter.firstHostTime == nil ? 0 : micStart - origin
        let sysLeadIn = sysWriter.firstHostTime == nil ? 0 : sysStart - origin
        Log.capture.info("Stop: mic \(self.micWriter.seconds, privacy: .public)s (+\(micLeadIn, privacy: .public)s), sys \(self.sysWriter.seconds, privacy: .public)s (+\(sysLeadIn, privacy: .public)s)")

        try FileManager.default.createDirectory(at: settings.outputRoot, withIntermediateDirectories: true)
        let audioURL = settings.outputRoot.appendingPathComponent("\(timestamp).m4a")
        try AudioMixdown.writeStereoM4A(mic: micWriter.url, micLeadIn: micLeadIn,
                                        sys: sysWriter.url, sysLeadIn: sysLeadIn,
                                        to: audioURL)
        return RecordingResult(timestamp: timestamp, startedAt: startedAt, duration: duration,
                               audioURL: audioURL, workDir: workDir)
    }

    /// Abandons the session and removes partial files.
    public func cancel() {
        watchdog?.cancel(); watchdog = nil
        stateLock.lock(); defer { stateLock.unlock() }
        started = false
        mic.stop(); tap.stop(); micWriter.close(); sysWriter.close()
        try? FileManager.default.removeItem(at: workDir)
    }
}

public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func hostTime(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    public static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }
}
