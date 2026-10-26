// Core Audio process-tap capture of all system audio output (macOS 14.2+).
// Pattern after AudioCap (BSD-2-Clause, Guilherme Rambo) and AudioTee (MIT, Nick Payne).
import AudioToolbox
import AVFoundation
import Foundation

public final class SystemAudioTap {
    /// Receives each captured buffer; the buffer memory is only valid for the duration of the call.
    public typealias BufferHandler = (AVAudioPCMBuffer, UInt64) -> Void

    public private(set) var format: AVAudioFormat?
    public private(set) var outputDeviceName: String = ""
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.esteiner.audiorecord.systemtap", qos: .userInitiated)
    private let excludedPIDs: [pid_t]

    /// - Parameter excludedPIDs: processes whose output is left out of the mix (default: none → everything).
    public init(excludedPIDs: [pid_t] = []) {
        self.excludedPIDs = excludedPIDs
    }

    deinit { stop() }

    public func start(handler: @escaping BufferHandler) throws {
        guard tapID == kAudioObjectUnknown else { return }

        // 1. Global tap: stereo mixdown of every process except the excluded ones.
        let excluded = try excludedPIDs.map { try AudioObjectID.translatePID($0) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.name = "AudioRecord system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap: AudioObjectID = kAudioObjectUnknown
        var err = AudioHardwareCreateProcessTap(description, &newTap)
        guard err == noErr, newTap.isValid else {
            throw AudioRecordError("System audio tap could not be created (OSStatus \(err)). Check System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        tapID = newTap

        var asbd = try tapID.readTapStreamDescription()
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            stop(); throw AudioRecordError("Unsupported tap stream format")
        }
        format = fmt

        // 2. Private aggregate device: default output as the clock source + the tap as input.
        let outputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputID.readDeviceUID()
        outputDeviceName = (try? outputID.readDeviceName()) ?? ""
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRecord Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var newAggregate: AudioObjectID = kAudioObjectUnknown
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &newAggregate)
        guard err == noErr, newAggregate.isValid else {
            stop(); throw AudioRecordError("Aggregate device could not be created (OSStatus \(err))")
        }
        aggregateID = newAggregate

        // 3. IO proc on our serial queue; wrap the input buffer list without copying.
        err = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, let fmt = self.format else { return }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inInputData, deallocator: nil) else { return }
            handler(buffer, inInputTime.pointee.mHostTime)
        }
        guard err == noErr else { stop(); throw AudioRecordError("IO proc could not be created (OSStatus \(err))") }

        err = AudioDeviceStart(aggregateID, ioProcID)
        guard err == noErr else { stop(); throw AudioRecordError("Aggregate device could not start (OSStatus \(err))") }
        Log.capture.info("System tap running: \(fmt.sampleRate, privacy: .public) Hz, \(fmt.channelCount, privacy: .public) ch, output \(self.outputDeviceName, privacy: .public)")
    }

    public func stop() {
        if aggregateID.isValid {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}
