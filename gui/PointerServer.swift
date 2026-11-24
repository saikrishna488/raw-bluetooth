import AppKit
import ApplicationServices
import Darwin

/// Clamp to actual displays, including layouts with gaps or negative origins.
enum PointerBounds {
    static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        var closest = point
        var distance = CGFloat.infinity
        for bounds in displays where bounds.width >= 1 && bounds.height >= 1 {
            let candidate = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1),
                                    y: min(max(point.y, bounds.minY), bounds.maxY - 1))
            let squared = pow(candidate.x - point.x, 2) + pow(candidate.y - point.y, 2)
            if squared < distance { closest = candidate; distance = squared }
        }
        return closest
    }

    static func displays() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

/// Unprivileged native pointer output. The USB worker sends decoded HID reports.
final class PointerServer {
    private static let maximumMotionAgeNanoseconds: UInt64 = 50_000_000
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "local.rawbluetooth.pointer", qos: .userInteractive)
    private let diagnosticsHandler: ((InputDiagnostics) -> Void)?
    private let path: String
    private var buttons = [Bool](repeating: false, count: 8)
    private var stopped = false
    private var sensitivity: CGFloat
    private var movementRemainderX: CGFloat = 0
    private var movementRemainderY: CGFloat = 0
    private var scrollPageLength: CGFloat
    private var scrollSensitivity: CGFloat
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    private lazy var keyboard = KeyboardOutput(queue: queue)
    private var mouseStates: [String: [Bool]] = [:]
    private var clickTimes = [TimeInterval](repeating: 0, count: 8)
    private var clickPositions = [CGPoint](repeating: .zero, count: 8)
    private var clickCounts = [Int64](repeating: 1, count: 8)
    private var cachedDisplays = [CGRect]()
    private var displayCacheTime: TimeInterval = 0
    private var diagnosticsEnabled: Bool
    private var latestMotionAgeMilliseconds = 0
    private var staleMotionDrops = 0
    private var largestReadBatch = 0
    private var lastDiagnosticsEmission: TimeInterval = 0

    init(path: String, sensitivity: Double = 1.0, scrollSensitivity: Double = 1.0, scrollPageLength: Double = 1.0,
         diagnosticsEnabled: Bool = false, diagnosticsHandler: ((InputDiagnostics) -> Void)? = nil) throws {
        guard AXIsProcessTrusted() else { throw NSError(domain: "RawBluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Raw Bluetooth in Accessibility to enable mouse control."]) }
        self.scrollPageLength = CGFloat(min(30, max(1, scrollPageLength)))
        self.path = path
        self.diagnosticsEnabled = diagnosticsEnabled
        self.diagnosticsHandler = diagnosticsHandler
        self.sensitivity = CGFloat(min(4.0, max(0.5, sensitivity)))
        self.scrollSensitivity = CGFloat(min(4.0, max(0.5, scrollSensitivity)))
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "RawBluetooth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pointer socket path is too long."]) }
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        descriptor = fd
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in
            bytes.withUnsafeBytes { input in target.copyBytes(from: input) }
        }
        let bound = withUnsafePointer(to: &address) { value in
            value.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        chmod(path, 0o600)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.read() }
        source.resume()
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pendingMotion: [String: Any]?
        var readCount = 0
        func flushMotion() {
            if let motion = pendingMotion {
                self.apply(motion)
                pendingMotion = nil
            }
        }
        while !stopped {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 { break }
            if count == 0 { continue }
            guard let report = binaryReport(buffer, count: count) else { continue }
            readCount += 1
            guard motionOnly(report) else {
                flushMotion()
                apply(report)
                continue
            }
            if let timing = motionTiming(report) {
                latestMotionAgeMilliseconds = Int(timing.age / 1_000_000)
                if timing.timestamp < timing.now && timing.now - timing.timestamp > Self.maximumMotionAgeNanoseconds {
                    // Do not replay relative movement accumulated while macOS
                    // was busy. Controls continue through the ordered path.
                    staleMotionDrops += 1
                    continue
                }
            }
            if let existing = pendingMotion, existing["device"] as? String != report["device"] as? String {
                flushMotion()
            }
            mergeMotion(report, into: &pendingMotion)
        }
        flushMotion()
        largestReadBatch = max(largestReadBatch, readCount)
        publishDiagnosticsIfNeeded()
    }

    /// Decode the versioned, private binary protocol emitted by DatagramSender.
    /// It intentionally carries only already-decoded HID state; no pointer
    /// coordinates or input history are written to disk.
    private func binaryReport(_ bytes: [UInt8], count: Int) -> [String: Any]? {
        guard count >= 12, bytes[0] == 1 else { return nil }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8 }
        func i16(_ offset: Int) -> Int64 { Int64(Int16(bitPattern: u16(offset))) }
        func u64(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<8 { value |= UInt64(bytes[offset + index]) << UInt64(index * 8) }
            return value
        }
        let device = String(u64(4))
        switch bytes[1] {
        case 1: // mouse
            let hasButtons = bytes[2] & 1 != 0
            guard count >= (hasButtons ? 21 : 28) else { return nil }
            var report: [String: Any] = ["device": device, "x": i16(12), "y": i16(14), "wheel": i16(16), "pan": i16(18)]
            if hasButtons {
                let values = bytes[20]
                for index in 0..<8 { report["button\(index + 1)"] = values & UInt8(1 << index) != 0 }
            } else {
                report["motion_timestamp_ns"] = NSNumber(value: Int64(bitPattern: u64(20)))
            }
            return report
        case 2: // keyboard
            guard count >= 14 else { return nil }
            let keyCount = Int(bytes[12]), consumerCount = Int(bytes[13])
            guard count == 14 + 2 * (keyCount + consumerCount) else { return nil }
            var offset = 14
            var keys = [Int](), consumer = [Int]()
            for _ in 0..<keyCount { keys.append(Int(u16(offset))); offset += 2 }
            for _ in 0..<consumerCount { consumer.append(Int(u16(offset))); offset += 2 }
            return ["kind": "keyboard", "device": device, "keys": keys, "consumer": consumer]
        case 3:
            return ["kind": "release", "device": device]
        default:
            return nil
        }
    }

    private func motionOnly(_ report: [String: Any]) -> Bool {
        guard report["kind"] == nil,
              !report.keys.contains(where: { $0.hasPrefix("button") }) else { return false }
        return ["x", "y", "wheel", "pan"].contains { report[$0] != nil }
    }

    private func mergeMotion(_ report: [String: Any], into pending: inout [String: Any]?) {
        guard var merged = pending else { pending = report; return }
        for key in ["x", "y", "wheel", "pan"] where report[key] != nil {
            let value = amount(report, key)
            let prior = amount(merged, key)
            merged[key] = max(Int64(-32768), min(Int64(32767), prior + value))
        }
        pending = merged
    }

    private func motionTiming(_ report: [String: Any]) -> (timestamp: UInt64, now: UInt64, age: UInt64)? {
        guard let number = report["motion_timestamp_ns"] as? NSNumber,
              number.int64Value > 0 else { return nil }
        let timestamp = UInt64(number.int64Value)
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return (timestamp, now, timestamp >= now ? 0 : now - timestamp)
    }

    private func publishDiagnosticsIfNeeded() {
        guard diagnosticsEnabled, let diagnosticsHandler else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDiagnosticsEmission >= 1 else { return }
        lastDiagnosticsEmission = now
        diagnosticsHandler(InputDiagnostics(latestMotionAgeMilliseconds: latestMotionAgeMilliseconds,
                                            staleMotionDrops: staleMotionDrops,
                                            largestReadBatch: largestReadBatch))
        largestReadBatch = 0
    }

    private func activeDisplays() -> [CGRect] {
        let now = ProcessInfo.processInfo.systemUptime
        if cachedDisplays.isEmpty || now - displayCacheTime >= 1 {
            cachedDisplays = PointerBounds.displays()
            displayCacheTime = now
        }
        return cachedDisplays
    }

    private func amount(_ report: [String: Any], _ key: String) -> Int64 {
        let value = (report[key] as? NSNumber)?.int64Value ?? 0
        return max(-32768, min(32767, value))
    }

    func setSensitivity(_ value: Double) {
        queue.async {
            self.sensitivity = CGFloat(min(4.0, max(0.5, value)))
            self.movementRemainderX = 0
            self.movementRemainderY = 0
        }
    }

    func setScrollSensitivity(_ value: Double) {
        queue.async {
            self.scrollSensitivity = CGFloat(min(4.0, max(0.5, value)))
            self.scrollRemainderX = 0
            self.scrollRemainderY = 0
        }
    }

    func setScrollPageLength(_ value: Double) {
        queue.async {
            self.scrollPageLength = CGFloat(min(30, max(1, value)))
            self.scrollRemainderY = 0
        }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        queue.async {
            self.diagnosticsEnabled = enabled
            self.lastDiagnosticsEmission = 0
        }
    }

    private func apply(_ report: [String: Any]) {
        let device = report["device"] as? String ?? "default"
        if report["kind"] as? String == "keyboard" {
            keyboard.apply(report, device: device)
            return
        }
        var report = report
        if report["kind"] as? String == "release" {
            keyboard.release(device: device)
            mouseStates.removeValue(forKey: device)
            for index in 0..<8 { report["button\(index + 1)"] = mouseStates.values.contains { $0[index] } }
        } else {
            var state = mouseStates[device] ?? [Bool](repeating: false, count: 8)
            for index in 0..<8 {
                if let down = report["button\(index + 1)"] as? Bool { state[index] = down }
            }
            mouseStates[device] = state
            for index in 0..<8 { report["button\(index + 1)"] = mouseStates.values.contains { $0[index] } }
        }
        guard let current = CGEvent(source: nil) else { return }
        var point = current.location
        let rawX = CGFloat(amount(report, "x")) * sensitivity + movementRemainderX
        let rawY = CGFloat(amount(report, "y")) * sensitivity + movementRemainderY
        let dx = Int64(rawX.rounded(.toNearestOrAwayFromZero))
        let dy = Int64(rawY.rounded(.toNearestOrAwayFromZero))
        movementRemainderX = rawX - CGFloat(dx)
        movementRemainderY = rawY - CGFloat(dy)
        let displays = activeDisplays()
        let origin = PointerBounds.clamp(point, to: displays)
        let proposed = CGPoint(x: origin.x + CGFloat(dx), y: origin.y + CGFloat(dy))
        point = PointerBounds.clamp(proposed, to: displays)
        // Discard movement beyond an edge so reversal responds immediately.
        if point.x != proposed.x { movementRemainderX = 0 }
        if point.y != proposed.y { movementRemainderY = 0 }
        if dx != 0 || dy != 0 {
            let button = buttons.firstIndex(of: true)
            let type: CGEventType = button == nil ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0)) ?? .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - origin.x).rounded()))
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - origin.y).rounded()))
            event?.flags.formUnion(keyboard.flags)
            event?.post(tap: .cghidEventTap)
        }
        for index in 0..<8 {
            guard let down = report["button\(index + 1)"] as? Bool, down != buttons[index] else { continue }
            let type: CGEventType = index == 0 ? (down ? .leftMouseDown : .leftMouseUp) : index == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            if down {
                let now = Date.timeIntervalSinceReferenceDate
                let distance = hypot(point.x - clickPositions[index].x, point.y - clickPositions[index].y)
                clickCounts[index] = now - clickTimes[index] <= NSEvent.doubleClickInterval && distance < 5 ? clickCounts[index] + 1 : 1
                clickTimes[index] = now
                clickPositions[index] = point
            }
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(index)) ?? .left)
            event?.setIntegerValueField(.mouseEventClickState, value: clickCounts[index])
            event?.flags.formUnion(keyboard.flags)
            event?.post(tap: .cghidEventTap)
            buttons[index] = down
        }
        let rawWheel = CGFloat(amount(report, "wheel")) * scrollSensitivity * scrollPageLength + scrollRemainderY
        let rawPan = CGFloat(amount(report, "pan")) * scrollSensitivity + scrollRemainderX
        let wheel = Int64(rawWheel.rounded(.toNearestOrAwayFromZero))
        let pan = Int64(rawPan.rounded(.toNearestOrAwayFromZero))
        scrollRemainderY = rawWheel - CGFloat(wheel)
        scrollRemainderX = rawPan - CGFloat(pan)
        if wheel != 0 || pan != 0 {
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(wheel), wheel2: Int32(pan), wheel3: 0)?.post(tap: .cghidEventTap)
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            var release: [String: Any] = [:]
            self.keyboard.releaseAll()
            self.mouseStates.removeAll()
            for index in 1...8 { release["button\(index)"] = false }
            self.apply(release)
            self.stopped = true
            self.source.cancel()
            unlink(self.path)
        }
    }
}
