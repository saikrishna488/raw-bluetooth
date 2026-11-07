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
        print("Pointer bounds checks passed")
    }
}
