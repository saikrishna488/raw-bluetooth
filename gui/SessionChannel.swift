import Foundation
import Darwin

/// Authenticated loopback transport for a single volatile driver session.
final class SessionChannel {
    private let listener: Int32
    private let queue = DispatchQueue(label: "local.rawbluetooth.session")
    private let token: String
    private let onEvent: ([String: Any]) -> Void
    private var listenerSource: DispatchSourceRead?
    private var connectionSource: DispatchSourceRead?
    private var connection: Int32 = -1
    private var authenticated = false
    private var pending = Data()
    private var pendingOutbound = [[String: Any]]()
    let port: UInt16

    init(token: String, onEvent: @escaping ([String: Any]) -> Void) throws {
        self.token = token
        self.onEvent = onEvent
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            let error = errno; Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &actual, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }) == 0 else {
            let error = errno; Darwin.close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(error))
        }
        self.listener = descriptor
        port = UInt16(bigEndian: actual.sin_port)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { Darwin.close(self.listener) }
        source.resume()
        listenerSource = source
    }

    private func acceptConnection() {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let descriptor = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listener, $0, &length) }
        }
        guard descriptor >= 0 else { return }
        connectionSource?.cancel()
        if connection >= 0 { Darwin.close(connection) }
        connection = descriptor
        authenticated = false
        pending.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { [weak self] in
            guard let self, self.connection == descriptor else { return }
            Darwin.close(descriptor)
            self.connection = -1
            self.authenticated = false
        }
        source.resume()
        connectionSource = source
    }

    private func read() {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.recv(connection, &bytes, bytes.count, 0)
        guard count > 0 else { connectionSource?.cancel(); return }
        pending.append(contentsOf: bytes.prefix(count))
        guard pending.count <= 64 * 1024 else { connectionSource?.cancel(); return }
        while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if !authenticated {
                guard message["type"] as? String == "hello", message["token"] as? String == token else {
                    connectionSource?.cancel(); return
                }
                authenticated = true
                let outbound = pendingOutbound
                pendingOutbound.removeAll(keepingCapacity: true)
                for item in outbound { sendNow(item) }
                continue
            }
            if message["type"] as? String == "event", let event = message["event"] as? [String: Any] {
                DispatchQueue.main.async { [weak self] in self?.onEvent(event) }
            }
        }
    }

    func send(_ message: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.authenticated, self.connection >= 0 else {
                // Retain startup commands and only the latest lease renewal.
                if message["type"] as? String != "heartbeat" || !self.pendingOutbound.contains(where: { $0["type"] as? String == "heartbeat" }) {
                    self.pendingOutbound.append(message)
                }
                if self.pendingOutbound.count > 64 { self.pendingOutbound.removeFirst() }
                return
            }
            self.sendNow(message)
        }
    }

    private func sendNow(_ message: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: message) else { return }
        var data = body + Data([10])
        while !data.isEmpty {
            let sent = data.withUnsafeBytes { Darwin.send(connection, $0.baseAddress, data.count, 0) }
            guard sent > 0 else { connectionSource?.cancel(); return }
            data.removeFirst(sent)
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.connectionSource?.cancel()
            self?.listenerSource?.cancel()
            self?.connectionSource = nil
            self?.listenerSource = nil
        }
    }
}
