// Property-access helpers adapted from AudioCap (https://github.com/insidegui/AudioCap),
// BSD-2-Clause, Copyright (c) Guilherme Rambo.
import AudioToolbox
import Foundation

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    var isValid: Bool { self != kAudioObjectUnknown }

    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice,
                                      defaultValue: AudioDeviceID(kAudioObjectUnknown))
    }

    static func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        let obj: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID(kAudioObjectUnknown), qualifier: pid)
        guard obj.isValid else { throw AudioRecordError("No Core Audio process object for pid \(pid)") }
        return obj
    }

    func readDeviceUID() throws -> String {
        try read(kAudioDevicePropertyDeviceUID, defaultValue: "" as CFString) as String
    }

    func readDeviceName() throws -> String {
        try read(kAudioObjectPropertyName, defaultValue: "" as CFString) as String
    }

    func readTapStreamDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    func read<T>(_ selector: AudioObjectPropertySelector, defaultValue: T) throws -> T {
        try read(selector, defaultValue: defaultValue, qualifierSize: 0, qualifierData: nil)
    }

    func read<T, Q>(_ selector: AudioObjectPropertySelector, defaultValue: T, qualifier: Q) throws -> T {
        var q = qualifier
        return try withUnsafeMutablePointer(to: &q) { ptr in
            try read(selector, defaultValue: defaultValue,
                     qualifierSize: UInt32(MemoryLayout<Q>.size), qualifierData: UnsafeRawPointer(ptr))
        }
    }

    private func read<T>(_ selector: AudioObjectPropertySelector, defaultValue: T,
                         qualifierSize: UInt32, qualifierData: UnsafeRawPointer?) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, qualifierSize, qualifierData, &size)
        guard err == noErr else { throw AudioRecordError("AudioObjectGetPropertyDataSize(\(selector)) failed: \(err)") }
        var value = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, qualifierSize, qualifierData, &size, ptr)
        }
        guard err == noErr else { throw AudioRecordError("AudioObjectGetPropertyData(\(selector)) failed: \(err)") }
        return value
    }
}
