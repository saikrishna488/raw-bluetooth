import AppKit
import ApplicationServices
import Darwin

/// Unprivileged native pointer output. The USB worker sends decoded HID reports.
final class PointerServer {
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "local.rawbluetooth.pointer")
    private let path: String
    private var buttons = [Bool](repeating: false, count: 8)
    private var stopped = false
    private var sensitivity: CGFloat
    private var movementRemainderX: CGFloat = 0
    private var movementRemainderY: CGFloat = 0
    private var scrollSensitivity: CGFloat
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0
    private lazy var keyboard = KeyboardOutput(queue: queue)
    private var mouseStates: [String: [Bool]] = [:]
    private var clickTimes = [TimeInterval](repeating: 0, count: 8)
    private var clickPositions = [CGPoint](repeating: .zero, count: 8)
    private var clickCounts = [Int64](repeating: 1, count: 8)

    init(path: String, sensitivity: Double = 1.0, scrollSensitivity: Double = 1.0) throws {
        guard AXIsProcessTrusted() else { throw NSError(domain: "RawBluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Raw Bluetooth in Accessibility to enable mouse control."]) }
        self.path = path
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
        while !stopped {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 { break }
            if count == 0 { continue }
            guard let report = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any] else { continue }
            apply(report)
        }
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
        point.x += CGFloat(dx)
        point.y += CGFloat(dy)
        if dx != 0 || dy != 0 {
            let button = buttons.firstIndex(of: true)
            let type: CGEventType = button == nil ? .mouseMoved : button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
            let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(button ?? 0)) ?? .left)
            event?.setIntegerValueField(.mouseEventDeltaX, value: dx)
            event?.setIntegerValueField(.mouseEventDeltaY, value: dy)
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
        let rawWheel = CGFloat(amount(report, "wheel")) * scrollSensitivity + scrollRemainderY
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
