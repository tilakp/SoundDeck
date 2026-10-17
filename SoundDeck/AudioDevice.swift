import CoreAudio
import Foundation

/// A CoreAudio output device the deck can play into.
///
/// Routing matters because the point of a soundboard is usually for *other people* to
/// hear it. Selecting a virtual device (BlackHole, Loopback, Soundflower) as the
/// output lets conferencing and streaming apps pick the deck up as a microphone
/// source instead of it only coming out of the local speakers.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String?

    /// Heuristic: virtual loopback drivers are the interesting ones for routing, so
    /// they get called out in the picker.
    var isLikelyVirtual: Bool {
        let needles = ["blackhole", "loopback", "soundflower", "virtual", "aggregate", "multi-output", "vb-cable"]
        let haystack = name.lowercased()
        return needles.contains { haystack.contains($0) }
    }
}

enum AudioDeviceList {
    /// Every device that has at least one output channel.
    static func outputDevices() -> [AudioDevice] {
        deviceIDs().compactMap { id in
            guard channelCount(of: id, scope: kAudioDevicePropertyScopeOutput) > 0 else { return nil }
            guard let name = stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
            return AudioDevice(id: id, name: name, uid: stringProperty(kAudioDevicePropertyDeviceUID, of: id))
        }
    }

    /// Every device that has at least one input channel.
    static func inputDevices() -> [AudioDevice] {
        deviceIDs().compactMap { id in
            guard channelCount(of: id, scope: kAudioDevicePropertyScopeInput) > 0 else { return nil }
            guard let name = stringProperty(kAudioObjectPropertyName, of: id) else { return nil }
            return AudioDevice(id: id, name: name, uid: stringProperty(kAudioDevicePropertyDeviceUID, of: id))
        }
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown ? deviceID : nil
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    /// The name of the default input device, or nil if there is no input device.
    static func defaultInputDeviceName() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return stringProperty(kAudioObjectPropertyName, of: deviceID)
    }

    /// Calls `handler` on the main queue when a device is added or removed, or when the
    /// default output or input changes. The listeners stay for the life of the application.
    static func observeChanges(_ handler: @escaping () -> Void) {
        let selectors = [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDefaultInputDevice]
        for selector in selectors {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                handler()
            }
        }
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func channelCount(of device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }

        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, bufferList) == noErr else { return 0 }

        let pointer = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return pointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
