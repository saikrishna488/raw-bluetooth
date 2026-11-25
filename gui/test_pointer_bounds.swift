import AppKit

@main
struct PointerBoundsTests {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        func check(_ input: CGPoint, _ expected: CGPoint, _ displays: [CGRect]) {
            precondition(PointerBounds.clamp(input, to: displays) == expected,
                         "Unexpected clamp for \(input)")
        }
        check(CGPoint(x: -400, y: 50), CGPoint(x: 0, y: 50), [screen])
        check(CGPoint(x: 2500, y: 50), CGPoint(x: 1919, y: 50), [screen])
        check(CGPoint(x: 50, y: -400), CGPoint(x: 50, y: 0), [screen])
        check(CGPoint(x: 50, y: 1500), CGPoint(x: 50, y: 1079), [screen])
        var point = CGPoint(x: 1910, y: 100)
        for _ in 0..<100 {
            point = PointerBounds.clamp(CGPoint(x: point.x + 100, y: point.y), to: [screen])
        }
        point = PointerBounds.clamp(CGPoint(x: point.x - 1, y: point.y), to: [screen])
        precondition(point.x == 1918, "Reverse movement must respond immediately")
        let left = CGRect(x: -1280, y: 0, width: 1280, height: 1024)
        check(CGPoint(x: -10, y: 100), CGPoint(x: -10, y: 100), [screen, left])
        let right = CGRect(x: 1920, y: 200, width: 1280, height: 1024)
        check(CGPoint(x: 1925, y: 250), CGPoint(x: 1925, y: 250), [screen, right])
        check(CGPoint(x: 1930, y: 100), CGPoint(x: 1919, y: 100), [screen, right])
        check(CGPoint(x: 20, y: 30), CGPoint(x: 20, y: 30), [])
        var report = RawBTInput()
        precondition(rawbt_parse_input([1, 2], 2, &report) == 0)
        var packet = [UInt8](repeating: 0, count: 28)
        packet[0] = 1
        packet[1] = 1
        packet[12] = 255
        packet[13] = 255
        packet[20] = 42
        precondition(rawbt_parse_input(packet, 27, &report) == 0)
        precondition(rawbt_parse_input(packet, packet.count, &report) == 1)
        precondition(report.x == -1 && report.timestamp == 42)

        let keyboard = rawbt_keyboard_create()
        precondition(keyboard != nil)
        defer { rawbt_keyboard_destroy(keyboard) }
        var transitions: [Int32] = []
        withUnsafeMutablePointer(to: &transitions) { owner in
            let record: RawBTKeyTransition = { context, usage, down, _ in
                context!.assumingMemoryBound(to: [Int32].self).pointee.append(down != 0 ? usage : -usage)
            }
            rawbt_keyboard_update(keyboard, 1, 0, [4, 224], 2, nil, 0, owner, record)
            rawbt_keyboard_update(keyboard, 2, 0, [4], 1, nil, 0, owner, record)
            rawbt_keyboard_update(keyboard, 1, 1, nil, 0, nil, 0, owner, record)
            rawbt_keyboard_update(keyboard, 0, 2, nil, 0, nil, 0, owner, record)
        }
        precondition(transitions == [224, 4, -224, -4])

        let pcm = rawbt_pcm_create()
        defer { rawbt_pcm_destroy(pcm) }
        let leftPCM: [Int16] = [0, 16384]
        let rightPCM: [Int16] = [0, -16384]
        var samples = 0
        let output = leftPCM.withUnsafeBytes { a in
            rightPCM.withUnsafeBytes { b in
                rawbt_pcm_convert(pcm, a.baseAddress, b.baseAddress, 2, 16, 0, 24000, &samples)
            }
        }
        precondition(samples == 8 && output != nil)
        precondition(Array(UnsafeBufferPointer(start: output, count: samples))
                     == [0, 0, 0.25, -0.25, 0.5, -0.5, 0.5, -0.5])
        print("Desktop input and PCM checks passed")
    }
}
