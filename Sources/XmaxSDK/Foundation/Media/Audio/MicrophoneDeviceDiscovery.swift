//
//  MicrophoneDeviceDiscovery.swift
//  XmaxSDK
//
//  Author: 翁跃庭 (Yueting Weng)
//  GitHub: https://github.com/Xmax-AI/XmaxSDK-MacOS
//
//  Copyright (c) 2026 XMAX.AI PTE. LTD.
//

import CoreAudio
import Foundation

/// Reads stable input identifiers and names without opening Core Audio devices.
enum MicrophoneDeviceDiscovery {

    /// Lists readable inputs and marks the system default from the same discovery operation.
    ///
    /// - Parameters:
    ///   - deviceIDs: The current system audio object identifiers.
    ///   - defaultDeviceID: The current default input audio object identifier.
    ///   - readDevice: Reads a live input's UID and name; nil omits unavailable or output-only objects.
    ///
    /// - Returns: Unique input UIDs sorted by their display names.
    static func list(
        deviceIDs: () -> [AudioDeviceID] = readDeviceIDs,
        defaultDeviceID: () -> AudioDeviceID? = readDefaultDeviceID,
        readDevice: (AudioDeviceID) -> (id: String, name: String)? = readInputDevice
    ) -> [MicrophoneDevice] {
        let defaultID = defaultDeviceID()
        var inputs: [String: MicrophoneDevice] = [:]
        for objectID in deviceIDs() {
            guard objectID != kAudioObjectUnknown,
                let description = readDevice(objectID),
                !description.id.isEmpty, !description.name.isEmpty
            else { continue }
            let input = MicrophoneDevice(
                id: description.id,
                name: description.name,
                isDefault: objectID == defaultID
            )
            if inputs[input.id] == nil || input.isDefault {
                inputs[input.id] = input
            }
        }
        return inputs.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// Reads the current audio object list, accounting for a list that shrinks during discovery.
    private static func readDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        let stride = UInt32(MemoryLayout<AudioDeviceID>.stride)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
            size > 0, size.isMultiple(of: stride)
        else { return [] }
        let capacity = size
        var devices = [AudioDeviceID](repeating: 0, count: Int(size / stride))
        let result = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard result == noErr, size <= capacity, size.isMultiple(of: stride) else { return [] }
        return Array(devices.prefix(Int(size / stride)))
    }

    /// Reads the default input without changing system routing.
    private static func readDefaultDeviceID() -> AudioDeviceID? {
        readIntegerProperty(
            kAudioHardwarePropertyDefaultInputDevice,
            device: AudioObjectID(kAudioObjectSystemObject)
        )
    }

    /// Reads a live input's UID and display name; output-only devices are excluded.
    private static func readInputDevice(
        _ device: AudioDeviceID
    ) -> (id: String, name: String)? {
        guard readIntegerProperty(kAudioDevicePropertyDeviceIsAlive, device: device) == 1 else { return nil }
        var input = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &input, 0, nil, &streamSize) == noErr,
            streamSize > 0,
            let uid = readStringProperty(kAudioDevicePropertyDeviceUID, device: device),
            let name = readStringProperty(kAudioObjectPropertyName, device: device)
        else { return nil }
        return (uid, name)
    }

    /// Reads one fixed-size Core Audio integer property.
    private static func readIntegerProperty(
        _ selector: AudioObjectPropertySelector,
        device: AudioObjectID
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr,
            size == UInt32(MemoryLayout<UInt32>.size)
        else { return nil }
        return value
    }

    /// Reads one immutable Core Audio string property.
    private static func readStringProperty(
        _ selector: AudioObjectPropertySelector,
        device: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let result = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard result == noErr else { return nil }
        return value as String?
    }
}
