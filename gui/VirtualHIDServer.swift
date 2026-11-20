import Foundation
import IOKit.hid
import Darwin

struct InputDiagnostics: Equatable {
    let latestMotionAgeMilliseconds: Int
    let staleMotionDrops: Int
    let largestReadBatch: Int
}

/// Presents decoded Bluetooth reports to macOS as one composite virtual HID device.
/// Creation is entitlement-gated by macOS; this intentionally has no CGEvent fallback.
final class VirtualHIDServer {
    static let maximumMotionAgeNanoseconds: UInt64 = 50_000_000

    static func shouldDiscardMotion(timestamp: UInt64, now: UInt64) -> Bool {
        timestamp < now && now - timestamp > maximumMotionAgeNanoseconds
    }
    private static let descriptor: [UInt8] = [
        // Report 1: relative mouse, eight buttons, X/Y/wheel/pan (signed 16-bit).
        0x05,0x01,0x09,0x02,0xa1,0x01,0x85,0x01,0x09,0x01,0xa1,0x00,
        0x05,0x09,0x19,0x01,0x29,0x08,0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,
        0x05,0x01,0x09,0x30,0x09,0x31,0x16,0x00,0x80,0x26,0xff,0x7f,0x75,0x10,0x95,0x02,0x81,0x06,
        0x09,0x38,0x16,0x00,0x80,0x26,0xff,0x7f,0x75,0x10,0x95,0x01,0x81,0x06,
        0x05,0x0c,0x0a,0x38,0x02,0x16,0x00,0x80,0x26,0xff,0x7f,0x75,0x10,0x95,0x01,0x81,0x06,
        0xc0,0xc0,
        // Report 2: keyboard-page bitmap for usages 0...231 (NKRO, modifiers included).
        0x05,0x01,0x09,0x06,0xa1,0x01,0x85,0x02,0x05,0x07,
        0x19,0x00,0x2a,0xe7,0x00,0x15,0x00,0x25,0x01,0x75,0x01,0x96,0xe8,0x00,0x81,0x02,0xc0,
        // Report 3: supported consumer/media usages.
        0x05,0x0c,0x09,0x01,0xa1,0x01,0x85,0x03,
        0x09,0xe9,0x09,0xea,0x09,0xe2,0x09,0xcd,0x09,0xb5,0x09,0xb6,0x0a,0x6f,0x00,0x0a,0x70,0x00,
        0x15,0x00,0x25,0x01,0x75,0x01,0x95,0x08,0x81,0x02,0xc0
    ]
    private static let consumerUsages = [0xe9, 0xea, 0xe2, 0xcd, 0xb5, 0xb6, 0x6f, 0x70]

    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let queue = DispatchQueue(label: "local.rawbluetooth.virtual-hid", qos: .userInteractive)
    private let diagnosticsHandler: ((InputDiagnostics) -> Void)?
    private let path: String
    private let device: IOHIDUserDevice
    private var stopped = false
    private var sensitivity: Double
    private var scrollSensitivity: Double
    private var scrollPageLength: Double
    private var movementRemainderX = 0.0
    private var movementRemainderY = 0.0
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0
    private var mouseStates = [String: [Bool]]()
    private var keyStates = [String: Set<Int>]()
    private var consumerStates = [String: Set<Int>]()
    private var latestMotionAgeMilliseconds = 0
    private var staleMotionDrops = 0
    private var largestReadBatch = 0
    private var lastDiagnosticsEmission: TimeInterval = 0
    private var diagnosticsEnabled: Bool

    init(path: String, sensitivity: Double = 1.0, scrollSensitivity: Double = 1.0, scrollPageLength: Double = 1.0,
         diagnosticsEnabled: Bool = false,
         diagnosticsHandler: ((InputDiagnostics) -> Void)? = nil) throws {
        self.path = path
        self.diagnosticsEnabled = diagnosticsEnabled
        self.diagnosticsHandler = diagnosticsHandler
        self.sensitivity = min(4.0, max(0.5, sensitivity))
        self.scrollSensitivity = min(4.0, max(0.5, scrollSensitivity))
        self.scrollPageLength = min(30, max(1, scrollPageLength))
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey as String: Data(Self.descriptor),
            kIOHIDVendorIDKey as String: 0x23a7,
            kIOHIDProductIDKey as String: 0x1960,
            kIOHIDVersionNumberKey as String: 1,
            kIOHIDManufacturerKey as String: "Raw Bluetooth",
            kIOHIDProductKey as String: "Raw Bluetooth Virtual HID",
            kIOHIDSerialNumberKey as String: "raw-bluetooth-input",
            kIOHIDTransportKey as String: "Virtual",
            kIOHIDPrimaryUsagePageKey as String: 1,
            kIOHIDPrimaryUsageKey as String: 2,
        ]
        guard let created = IOHIDUserDeviceCreateWithProperties(kCFAllocatorDefault, properties as CFDictionary, 0) else {
            throw NSError(domain: "RawBluetooth", code: 20, userInfo: [NSLocalizedDescriptionKey: "Virtual HID output requires an Apple-signed build with the com.apple.developer.hid.virtual.device entitlement."])
        }
        device = created
        IOHIDUserDeviceSetDispatchQueue(device, queue)
        IOHIDUserDeviceActivate(device)

        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            IOHIDUserDeviceCancel(device)
            throw NSError(domain: "RawBluetooth", code: 2, userInfo: [NSLocalizedDescriptionKey: "Pointer socket path is too long."])
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_DGRAM, 0)
        descriptor = fd
        guard fd >= 0 else { IOHIDUserDeviceCancel(device); throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in bytes.withUnsafeBytes { target.copyBytes(from: $0) } }
        let bound = withUnsafePointer(to: &address) { value in
            value.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            Darwin.close(fd); IOHIDUserDeviceCancel(device)
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
            guard count > 0,
                  let report = try? JSONSerialization.jsonObject(with: Data(buffer.prefix(count))) as? [String: Any] else { continue }
            readCount += 1
            guard motionOnly(report) else {
                flushMotion()
                apply(report)
                continue
            }
            if let timing = motionTiming(report) {
                latestMotionAgeMilliseconds = Int(timing.age / 1_000_000)
                if Self.shouldDiscardMotion(timestamp: timing.timestamp, now: timing.now) {
                    // Relative movement held during a system stall cannot be
                    // replayed without making the cursor visibly jump.
                    staleMotionDrops += 1
                    continue
                }
            }
            if let pending = pendingMotion, pending["device"] as? String != report["device"] as? String {
                flushMotion()
            }
            mergeMotion(report, into: &pendingMotion)
        }
        flushMotion()
        largestReadBatch = max(largestReadBatch, readCount)
        publishDiagnosticsIfNeeded()
    }

    private func motionOnly(_ report: [String: Any]) -> Bool {
        guard report["kind"] == nil,
              !report.keys.contains(where: { $0.hasPrefix("button") }) else { return false }
        return ["x", "y", "wheel", "pan"].contains { report[$0] != nil }
    }

    private func motionTiming(_ report: [String: Any]) -> (timestamp: UInt64, now: UInt64, age: UInt64)? {
        guard let number = report["motion_timestamp_ns"] as? NSNumber,
              number.int64Value > 0 else { return nil }
        let timestamp = UInt64(number.int64Value)
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        return (timestamp, now, timestamp >= now ? 0 : now - timestamp)
    }

    private func mergeMotion(_ report: [String: Any], into pending: inout [String: Any]?) {
        guard var merged = pending else { pending = report; return }
        for key in ["x", "y", "wheel", "pan"] where report[key] != nil {
            merged[key] = max(Int64(-32768), min(Int64(32767), amount(merged, key) + amount(report, key)))
        }
        merged["motion_timestamp_ns"] = report["motion_timestamp_ns"]
        pending = merged
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

    private func amount(_ report: [String: Any], _ key: String) -> Int64 {
        let value = (report[key] as? NSNumber)?.int64Value ?? 0
        return max(-32768, min(32767, value))
    }

    private func emit(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let result = bytes.withUnsafeBufferPointer { IOHIDUserDeviceHandleReportWithTimeStamp(device, mach_absolute_time(), $0.baseAddress!, bytes.count) }
        if result != kIOReturnSuccess { /* The device is being cancelled; stop reports without blocking input. */ }
    }

    private func emitMouse(_ report: [String: Any]) {
        let deviceID = report["device"] as? String ?? "default"
        var state = mouseStates[deviceID] ?? [Bool](repeating: false, count: 8)
        for index in 0..<8 where report["button\(index + 1)"] != nil { state[index] = report["button\(index + 1)"] as? Bool ?? false }
        mouseStates[deviceID] = state
        let buttons = mouseStates.values.reduce(into: UInt8(0)) { value, item in
            for index in 0..<8 where item[index] { value |= UInt8(1 << index) }
        }
        func scaled(_ value: Int64, multiplier: Double, remainder: inout Double) -> Int16 {
            let raw = Double(value) * multiplier + remainder
            let rounded = max(-32768, min(32767, Int64(raw.rounded(.toNearestOrAwayFromZero))))
            remainder = raw - Double(rounded)
            return Int16(rounded)
        }
        let x = scaled(amount(report, "x"), multiplier: sensitivity, remainder: &movementRemainderX)
        let y = scaled(amount(report, "y"), multiplier: sensitivity, remainder: &movementRemainderY)
        let wheel = scaled(amount(report, "wheel"), multiplier: scrollSensitivity * scrollPageLength, remainder: &scrollRemainderY)
        let pan = scaled(amount(report, "pan"), multiplier: scrollSensitivity, remainder: &scrollRemainderX)
        guard x != 0 || y != 0 || wheel != 0 || pan != 0 || report.keys.contains(where: { $0.hasPrefix("button") }) else { return }
        var bytes = [UInt8(1), buttons]
        for value in [x, y, wheel, pan] {
            let raw = UInt16(bitPattern: value)
            bytes.append(UInt8(raw & 0xff)); bytes.append(UInt8(raw >> 8))
        }
        emit(bytes)
    }

    private func emitKeyboard() {
        let held = keyStates.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        var bytes = [UInt8](repeating: 0, count: 30); bytes[0] = 2
        for usage in held where usage >= 0 && usage <= 231 { bytes[1 + usage / 8] |= UInt8(1 << (usage % 8)) }
        emit(bytes)
        let consumer = consumerStates.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        var flags: UInt8 = 0
        for (index, usage) in Self.consumerUsages.enumerated() where consumer.contains(usage) { flags |= UInt8(1 << index) }
        emit([3, flags])
    }

    private func apply(_ report: [String: Any]) {
        let deviceID = report["device"] as? String ?? "default"
        if report["kind"] as? String == "keyboard" {
            keyStates[deviceID] = Set((report["keys"] as? [Int] ?? []).filter { $0 >= 0 && $0 <= 231 })
            consumerStates[deviceID] = Set((report["consumer"] as? [Int] ?? []).filter { Self.consumerUsages.contains($0) })
            emitKeyboard()
        } else if report["kind"] as? String == "release" {
            mouseStates.removeValue(forKey: deviceID)
            keyStates.removeValue(forKey: deviceID)
            consumerStates.removeValue(forKey: deviceID)
            emitMouse(["device": deviceID, "button1": false, "button2": false, "button3": false, "button4": false, "button5": false, "button6": false, "button7": false, "button8": false])
            emitKeyboard()
        } else {
            emitMouse(report)
        }
    }

    func setSensitivity(_ value: Double) { queue.async { self.sensitivity = min(4.0, max(0.5, value)); self.movementRemainderX = 0; self.movementRemainderY = 0 } }
    func setScrollSensitivity(_ value: Double) { queue.async { self.scrollSensitivity = min(4.0, max(0.5, value)); self.scrollRemainderX = 0; self.scrollRemainderY = 0 } }
    func setScrollPageLength(_ value: Double) { queue.async { self.scrollPageLength = min(30, max(1, value)); self.scrollRemainderY = 0 } }
    func setDiagnosticsEnabled(_ enabled: Bool) { queue.async { self.diagnosticsEnabled = enabled; self.lastDiagnosticsEmission = 0 } }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.mouseStates.removeAll()
            self.keyStates.removeAll()
            self.consumerStates.removeAll()
            self.emit([1, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            self.emitKeyboard()
            self.stopped = true
            self.source.cancel()
            IOHIDUserDeviceCancel(self.device)
            unlink(self.path)
        }
    }
}
