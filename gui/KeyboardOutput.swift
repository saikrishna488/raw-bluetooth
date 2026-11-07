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
    private var held: [String: Set<Int>] = [:]
    private var consumers: [String: Set<Int>] = [:]
    private var current = Set<Int>()
    private var media = Set<Int>()
    private var caps = false
    private let queue: DispatchQueue
    private var repeatTimer: DispatchSourceTimer?
    private var repeating: Int?

    init(queue: DispatchQueue) { self.queue = queue }

    var flags: CGEventFlags {
        var result: CGEventFlags = []
        if current.contains(224) || current.contains(228) { result.insert(.maskControl) }
        if current.contains(225) || current.contains(229) { result.insert(.maskShift) }
        if current.contains(226) || current.contains(230) { result.insert(.maskAlternate) }
        if current.contains(227) || current.contains(231) { result.insert(.maskCommand) }
        if caps { result.insert(.maskAlphaShift) }
        return result
    }

    func apply(_ report: [String: Any], device: String) {
        let keys = (report["keys"] as? [Int] ?? []).filter { Self.keyMap[$0] != nil }
        let consumer = (report["consumer"] as? [Int] ?? []).filter { Self.mediaMap[$0] != nil }
        held[device] = Set(keys)
        consumers[device] = Set(consumer)
        reconcile()
    }

    func release(device: String) {
        held.removeValue(forKey: device)
        consumers.removeValue(forKey: device)
        reconcile()
    }

    func releaseAll() {
        held.removeAll()
        consumers.removeAll()
        reconcile()
    }

    private func key(_ usage: Int, down: Bool, autoRepeat: Bool = false) {
        guard let code = Self.keyMap[usage] else { return }
        if !autoRepeat {
            if down { current.insert(usage) } else { current.remove(usage) }
            if usage == 57 && down { caps.toggle() }
        }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        if usage >= 224 { event?.type = .flagsChanged }
        event?.flags = flags
        if autoRepeat { event?.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event?.post(tap: .cghidEventTap)
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

    private func reconcile() {
        let next = held.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        let releases = current.subtracting(next)
        let presses = next.subtracting(current)
        if let repeating = repeating, releases.contains(repeating) {
            repeatTimer?.cancel()
            repeatTimer = nil
            self.repeating = nil
        }
        for usage in releases.sorted(by: { ($0 >= 224 ? 1 : 0, $0) < ($1 >= 224 ? 1 : 0, $1) }) { key(usage, down: false) }
        for usage in presses.sorted(by: { ($0 >= 224 ? 0 : 1, $0) < ($1 >= 224 ? 0 : 1, $1) }) {
            key(usage, down: true)
            if usage < 224 && usage != 57 { startRepeat(usage) }
        }
        let nextMedia = consumers.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        for usage in media.subtracting(nextMedia) { mediaKey(usage, down: false) }
        for usage in nextMedia.subtracting(media) { mediaKey(usage, down: true) }
        media = nextMedia
    }
}
