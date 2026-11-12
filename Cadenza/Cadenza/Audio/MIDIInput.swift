import CoreMIDI
import Foundation

/// Listens to every connected MIDI source (USB, Bluetooth, network) and reports note events
/// on the main thread. New devices are picked up automatically when they are plugged in.
final class MIDIInput {
    var onNoteOn: ((_ pitch: Int, _ velocity: Int) -> Void)?
    var onNoteOff: ((_ pitch: Int) -> Void)?
    var onDevicesChanged: (([String]) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var started = false

    func start() {
        guard !started else { return }
        started = true

        let status = MIDIClientCreateWithBlock("Cadenza" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.connectSources() }
            }
        }
        guard status == noErr else {
            print("MIDI client could not be created: \(status)")
            return
        }
        MIDIInputPortCreateWithProtocol(client, "Cadenza Input" as CFString, ._1_0, &port) { [weak self] list, _ in
            self?.handle(list)
        }
        connectSources()
    }

    func connectSources() {
        var names: [String] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            MIDIPortDisconnectSource(port, source)
            MIDIPortConnectSource(port, source, nil)
            names.append(Self.displayName(of: source))
        }
        onDevicesChanged?(names)
    }

    private static func displayName(of object: MIDIObjectRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &name) == noErr,
           let value = name?.takeRetainedValue() {
            return value as String
        }
        return "MIDI device"
    }

    /// Runs on CoreMIDI's thread. Decodes Universal MIDI Packets carrying MIDI 1.0 channel voice messages.
    private func handle(_ list: UnsafePointer<MIDIEventList>) {
        var messages: [(status: UInt8, data1: UInt8, data2: UInt8)] = []
        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            var words: [UInt32] = []
            withUnsafeBytes(of: packet.pointee.words) { raw in
                words = Array(raw.bindMemory(to: UInt32.self).prefix(count))
            }
            var i = 0
            while i < words.count {
                let word = words[i]
                let messageType = word >> 28
                if messageType == 0x2 {
                    messages.append((UInt8((word >> 16) & 0xFF), UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F)))
                }
                i += Self.wordCount(messageType: messageType)
            }
        }
        guard !messages.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for m in messages {
                switch m.status & 0xF0 {
                case 0x90 where m.data2 > 0: self.onNoteOn?(Int(m.data1), Int(m.data2))
                case 0x90, 0x80: self.onNoteOff?(Int(m.data1))
                default: break
                }
            }
        }
    }

    /// Size of a Universal MIDI Packet, in 32-bit words, by message type.
    static func wordCount(messageType: UInt32) -> Int {
        switch messageType {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}
