import Foundation
import CoreBluetooth

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen = Set<UUID>()
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let names = [0: "unknown", 1: "resetting", 2: "unsupported", 3: "unauthorized", 4: "poweredOff", 5: "poweredOn"]
        print("Bluetooth state: \(names[central.state.rawValue] ?? "unexpected")")
        fflush(stdout)
        if central.state == .poweredOn {
            print("Scanning all advertised BLE services for 45 seconds. Put M196 in pairing mode now.")
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) {
                central.stopScan()
                print("Finished: \(self.seen.count) distinct BLE advertisers discovered.")
                exit(0)
            }
        } else if central.state == .unsupported || central.state == .unauthorized {
            exit(2)
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "unnamed"
        let target = name.lowercased().contains("m196") || name.lowercased().contains("logi")
        let first = seen.insert(peripheral.identifier).inserted
        if first || target {
            print("\(target ? "POSSIBLE MOUSE" : "DEVICE") name=\(name) id=\(peripheral.identifier) RSSI=\(RSSI) advertisement=\(advertisementData)")
            fflush(stdout)
        }
    }
}
let scanner = Scanner()
DispatchQueue.main.asyncAfter(deadline: .now() + 65) {
    print("Timed out waiting for Bluetooth readiness.")
    exit(3)
}
RunLoop.main.run()
