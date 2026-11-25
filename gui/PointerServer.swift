import AppKit
import ApplicationServices
import Darwin

/// Clamp to actual displays, including layouts with gaps or negative origins.
enum PointerBounds {
    static func clamp(_ point: CGPoint, to displays: [CGRect]) -> CGPoint {
        rawbt_clamp(point, displays, displays.count)
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
    private var stopped = false
    private let pointer: UnsafeMutableRawPointer
    private lazy var keyboard = KeyboardOutput(queue: queue)
    private var diagnosticsEnabled: Bool
    private var latestMotionAgeMilliseconds = 0
    private var staleMotionDrops = 0
    private var largestReadBatch = 0
    private var lastDiagnosticsEmission: TimeInterval = 0

    init(path: String, sensitivity: Double = 1.0, scrollSensitivity: Double = 1.0, scrollPageLength: Double = 1.0,
         diagnosticsEnabled: Bool = false, diagnosticsHandler: ((InputDiagnostics) -> Void)? = nil) throws {
        guard AXIsProcessTrusted() else { throw NSError(domain: "RawBluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Raw Bluetooth in Accessibility to enable mouse control."]) }
        self.path = path
        self.diagnosticsEnabled = diagnosticsEnabled
        self.diagnosticsHandler = diagnosticsHandler
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
        guard let pointer = rawbt_pointer_create(min(4, max(0.5, sensitivity)),
                                                 min(4, max(0.5, scrollSensitivity)),
                                                 min(30, max(1, scrollPageLength))) else {
            Darwin.close(fd)
            unlink(path)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        self.pointer = pointer
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.read() }
        source.resume()
    }

    private func read() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var readCount = 0
        while !stopped {
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 { break }
            if count == 0 { continue }
            var report = RawBTInput()
            guard rawbt_parse_input(buffer, count, &report) != 0 else { continue }
            readCount += 1
            if report.kind == 1, report.has_buttons == 0,
               report.timestamp > 0, report.timestamp <= UInt64(Int64.max) {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let age = report.timestamp < now ? now - report.timestamp : 0
                latestMotionAgeMilliseconds = Int(age / 1_000_000)
                if age > Self.maximumMotionAgeNanoseconds {
                    // Do not replay relative movement accumulated while macOS
                    // was busy. Controls continue through the ordered path.
                    staleMotionDrops += 1
                    continue
                }
            }
            // DatagramSender already coalesces only while its native queue is
            // congested. Applying each received motion preserves the mouse's
            // report cadence instead of adding a second batch-level merge.
            if report.kind == 2 {
                var offset = 14
                func usages(_ count: UInt8) -> [UInt16] {
                    (0..<Int(count)).map { _ in
                        defer { offset += 2 }
                        return UInt16(buffer[offset]) | (UInt16(buffer[offset + 1]) << 8)
                    }
                }
                let keys = usages(report.keys)
                let consumer = usages(report.consumers)
                keyboard.apply(keys: keys, consumer: consumer, device: report.device)
            } else {
                apply(report)
            }
        }
        largestReadBatch = max(largestReadBatch, readCount)
        publishDiagnosticsIfNeeded()
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

    deinit { rawbt_pointer_destroy(pointer) }

    func setSensitivity(_ value: Double) {
        queue.async { rawbt_pointer_set_sensitivity(self.pointer, min(4, max(0.5, value))) }
    }

    func setScrollSensitivity(_ value: Double) {
        queue.async { rawbt_pointer_set_scroll(self.pointer, min(4, max(0.5, value))) }
    }

    func setScrollPageLength(_ value: Double) {
        queue.async { rawbt_pointer_set_page(self.pointer, min(30, max(1, value))) }
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        queue.async {
            self.diagnosticsEnabled = enabled
            self.lastDiagnosticsEmission = 0
        }
    }

    private func apply(_ report: RawBTInput) {
        if report.kind == 3 { keyboard.release(device: report.device) }
        var report = report
        let clickInterval = report.has_buttons != 0 ? NSEvent.doubleClickInterval : 0
        rawbt_pointer_apply(pointer, &report, 0, keyboard.flags, clickInterval)
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.keyboard.releaseAll()
            var release = RawBTInput()
            release.kind = 3
            rawbt_pointer_apply(self.pointer, &release, 1, self.keyboard.flags, 0)
            self.stopped = true
            self.source.cancel()
            unlink(self.path)
        }
    }
}
