import Foundation

@main
struct InputLatencyTests {
    static func main() {
        let now: UInt64 = 1_000_000_000
        precondition(!VirtualHIDServer.shouldDiscardMotion(timestamp: now - 50_000_000, now: now))
        precondition(VirtualHIDServer.shouldDiscardMotion(timestamp: now - 50_000_001, now: now))
        precondition(!VirtualHIDServer.shouldDiscardMotion(timestamp: now + 1, now: now))
        print("Input latency checks passed")
    }
}
