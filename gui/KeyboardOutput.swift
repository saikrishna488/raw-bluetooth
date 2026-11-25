import AppKit

/// USB HID usage -> macOS virtual key code (HIToolbox Events.h).
/// Key states remain in memory and are never written to the app's activity log.
final class KeyboardOutput {
    static let keyMap: [Int: CGKeyCode] = [
        4:0,5:11,6:8,7:2,8:14,9:3,10:5,11:4,12:34,13:38,14:40,15:37,
        16:46,17:45,18:31,19:35,20:12,21:15,22:1,23:17,24:32,25:9,26:13,
        27:7,28:16,29:6,30:18,31:19,32:20,33:21,34:23,35:22,36:26,37:28,
        38:25,39:29,40:36,41:53,42:51,43:48,44:49,45:27,46:24,47:33,
        48:30,49:42,50:42,51:41,52:39,53:50,54:43,55:47,56:44,57:57,
        58:122,59:120,60:99,61:118,62:96,63:97,64:98,65:100,66:101,
        67:109,68:103,69:111,73:114,74:115,75:116,76:117,77:119,78:121,
        79:124,80:123,81:125,82:126,83:71,84:75,85:67,86:78,87:69,88:76,
        89:83,90:84,91:85,92:86,93:87,94:88,95:89,96:91,97:92,98:82,99:65,
        100:10,101:110,103:81,104:105,105:107,106:113,107:106,108:64,
        109:79,110:80,111:90,
        224:59,225:56,226:58,227:55,228:62,229:60,230:61,231:54
    ]
    static let mediaMap: [Int: Int] = [0xe9:0,0xea:1,0xe2:7,0xcd:16,0xb5:17,0xb6:18,0x6f:2,0x70:3]
    private let state = rawbt_keyboard_create()
    private var current = Set<Int>()
    private var caps = false
    private let queue: DispatchQueue
    private var repeatTimer: DispatchSourceTimer?
    private var repeating: Int?

    init(queue: DispatchQueue) { self.queue = queue }

    deinit { rawbt_keyboard_destroy(state) }

    var flags: CGEventFlags {
        var result: CGEventFlags = []
        if current.contains(224) || current.contains(228) { result.insert(.maskControl) }
        if current.contains(225) || current.contains(229) { result.insert(.maskShift) }
        if current.contains(226) || current.contains(230) { result.insert(.maskAlternate) }
        if current.contains(227) || current.contains(231) { result.insert(.maskCommand) }
        if caps { result.insert(.maskAlphaShift) }
        return result
    }

    func apply(keys: [UInt16], consumer: [UInt16], device: UInt64) {
        update(device: device, mode: 0,
               keys: keys.filter { Self.keyMap[Int($0)] != nil },
               consumer: consumer.filter { Self.mediaMap[Int($0)] != nil })
    }

    func release(device: UInt64) { update(device: device, mode: 1) }

    func releaseAll() { update(device: 0, mode: 2) }

    private func update(device: UInt64, mode: Int32, keys: [UInt16] = [], consumer: [UInt16] = []) {
        rawbt_keyboard_update(state, device, mode, keys, keys.count, consumer, consumer.count,
                              Unmanaged.passUnretained(self).toOpaque()) { owner, usage, down, media in
            guard let owner else { return }
            let output = Unmanaged<KeyboardOutput>.fromOpaque(owner).takeUnretainedValue()
            let usage = Int(usage)
            if media != 0 {
                output.mediaKey(usage, down: down != 0)
                return
            }
            if down == 0 && output.repeating == usage {
                output.repeatTimer?.cancel()
                output.repeatTimer = nil
                output.repeating = nil
            }
            output.key(usage, down: down != 0)
            if down != 0 && usage < 224 && usage != 57 { output.startRepeat(usage) }
        }
    }

    private func key(_ usage: Int, down: Bool, autoRepeat: Bool = false) {
        guard let code = Self.keyMap[usage] else { return }
        if !autoRepeat {
            if down { current.insert(usage) } else { current.remove(usage) }
            if usage == 57 && down { caps.toggle() }
        }
        rawbt_post_key(code, down ? 1 : 0, usage >= 224 ? 1 : 0, autoRepeat ? 1 : 0, flags)
    }

    private func mediaKey(_ usage: Int, down: Bool) {
        guard let code = Self.mediaMap[usage] else { return }
        let data = (code << 16) | ((down ? 0x0a : 0x0b) << 8)
        NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
    }

    private func startRepeat(_ usage: Int) {
        repeatTimer?.cancel()
        repeating = usage
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0.2, NSEvent.keyRepeatDelay), repeating: max(0.02, NSEvent.keyRepeatInterval))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.current.contains(usage) else { return }
            self.key(usage, down: true, autoRepeat: true)
        }
        repeatTimer = timer
        timer.resume()
    }

}
