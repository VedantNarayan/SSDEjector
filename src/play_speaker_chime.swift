import Cocoa
import CoreAudio
import AudioToolbox
import Foundation

// ==============================================================================
// CoreAudio Physical Speaker Router
// Routes sound to built-in laptop speakers at 100% and restores previous output
// ==============================================================================

func playChime() {
    var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var originalDeviceID: AudioDeviceID = 0
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, &size, &originalDeviceID)

    let getVolScript = "output volume of (get volume settings)"
    let getMuteScript = "output muted of (get volume settings)"
    var origVol = 50
    var origMuted = false

    if let vDesc = NSAppleScript(source: getVolScript)?.executeAndReturnError(nil).stringValue, let v = Int(vDesc) {
        origVol = v
    }
    if let mDesc = NSAppleScript(source: getMuteScript)?.executeAndReturnError(nil).stringValue {
        origMuted = (mDesc == "true")
    }

    var propAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var dataSize: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize)
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propAddress, 0, nil, &dataSize, &deviceIDs)

    var builtInSpeakerID: AudioDeviceID?
    for id in deviceIDs {
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport)

        var streamSize: UInt32 = 0
        var sAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyDataSize(id, &sAddr, 0, nil, &streamSize)

        if transport == kAudioDeviceTransportTypeBuiltIn && streamSize > 0 {
            builtInSpeakerID = id
            break
        }
    }

    if let speakerID = builtInSpeakerID {
        var targetID = speakerID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, size, &targetID)
    }

    let setMaxScript = "set volume without output muted\nset volume output volume 100"
    NSAppleScript(source: setMaxScript)?.executeAndReturnError(nil)

    let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)
    sound?.play()
    Thread.sleep(forTimeInterval: 0.85)

    if originalDeviceID != 0 {
        var restoreID = originalDeviceID
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultDeviceAddress, 0, nil, size, &restoreID)
    }

    let restoreScript = "set volume output volume \(origVol)\n" + (origMuted ? "set volume with output muted" : "")
    NSAppleScript(source: restoreScript)?.executeAndReturnError(nil)
}

playChime()
