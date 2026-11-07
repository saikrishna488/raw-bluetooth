import AppKit
import SwiftUI
import Foundation
import ApplicationServices
import ServiceManagement

struct NearbyDevice: Identifiable {
    var address: String
    var name: String
    var rssi: Int
    var connectable: Bool
    var classicAvailable: Bool
    var category: String
    var lastSeen: Date
    var id: String { address }
    var title: String { name.isEmpty ? "Unnamed device" : name }
    var symbol: String {
        if category == "Mouse" { return "computermouse.fill" }
        if category == "Keyboard" { return "keyboard.fill" }
        if category == "Audio" { return "airpodspro" }
        if name.lowercased().contains("airpod") { return "airpodspro" }
        if name.lowercased().contains("iphone") { return "iphone" }
        return "dot.radiowaves.left.and.right"
    }
}

final class BluetoothModel: ObservableObject {
    @Published var devices: [String: NearbyDevice] = [:]
    @Published var selection: String?
    @Published var status = "Ready to discover"
    @Published var phase = "idle"
    @Published var active = false
    @Published var scanning = false
    @Published var connectedAddresses = Set<String>()
    @Published var audioAddresses = Set<String>()
    @Published var audioPendingAddress: String?
    @Published var pendingAddress: String?
    @Published var pairingCode: String?
    @Published var reportCounts: [String: Int] = [:]
    @Published var savedDevices: [String: Bool] = [:]
    @Published var reports = 0
    @Published var errorMessage: String?
    @Published var logs: [String] = []
    @Published var query = ""
    @Published var filter = "All devices"
    @Published var stopping = false
    @Published var pointerAllowed = AXIsProcessTrusted()
    @Published var mouseSensitivity: Double = UserDefaults.standard.object(forKey: "mouseSensitivity") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(mouseSensitivity, forKey: "mouseSensitivity")
            pointer?.setSensitivity(mouseSensitivity)
        }
    }
    @Published var scrollSensitivity: Double = UserDefaults.standard.object(forKey: "scrollSensitivity") as? Double ?? 1.0 {
        didSet {
            UserDefaults.standard.set(scrollSensitivity, forKey: "scrollSensitivity")
            pointer?.setScrollSensitivity(scrollSensitivity)
        }
    }
    @Published var runInBackground = UserDefaults.standard.object(forKey: "runInBackground") as? Bool ?? true {
        didSet { UserDefaults.standard.set(runInBackground, forKey: "runInBackground") }
    }
    @Published var startHidden = UserDefaults.standard.bool(forKey: "startHidden") {
        didSet { UserDefaults.standard.set(startHidden, forKey: "startHidden") }
    }
    @Published var connectOnLaunch = UserDefaults.standard.object(forKey: "connectOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(connectOnLaunch, forKey: "connectOnLaunch") }
    }
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var loginError: String?

    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !preview else { return }
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { loginError = error.localizedDescription }
        refreshLoginStatus()
    }

    var backend: Process?
    var pointer: PointerServer?
    var session: URL?
    var timer: Timer?
    var eventOffset: UInt64 = 0
    var pending = Data()
    var heartbeatCounter = 0
    let source: URL
    let preview: Bool

    init() {
        source = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "DriverSourceDirectory") as? String ?? FileManager.default.currentDirectoryPath)
        preview = CommandLine.arguments.contains("--preview")
        timer = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer!, forMode: .common)
        if let data = try? Data(contentsOf: source.appendingPathComponent("saved-devices.json")),
           let records = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
            for (address, info) in records {
                savedDevices[address] = info["auto_reconnect"] as? Bool ?? true
            }
        }
        if preview {
            status = "Interface preview · no hardware session"
            phase = "preview"
        }
    }

    var chosen: NearbyDevice? { selection.flatMap { devices[$0] } }
    var busy: Bool { pendingAddress != nil }
    var connectedAddress: String? { connectedAddresses.first }
    var visibleDevices: [NearbyDevice] {
        devices.values.filter { device in
            (filter != "Mice" || device.category == "Mouse") &&
            (filter != "Keyboards" || device.category == "Keyboard") &&
            (filter != "Audio" || device.category == "Audio") &&
            (filter != "Saved" || savedDevices[device.address] != nil) &&
            (filter != "Connectable" || device.connectable) &&
            (query.isEmpty || device.title.localizedCaseInsensitiveContains(query) || device.address.localizedCaseInsensitiveContains(query))
        }.sorted {
            if connectedAddresses.contains($0.address) != connectedAddresses.contains($1.address) { return connectedAddresses.contains($0.address) }
            if ($0.category == "Mouse") != ($1.category == "Mouse") { return $0.category == "Mouse" }
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.address < $1.address
        }
    }

    func log(_ text: String) {
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("\(date)  \(text)")
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }

    func write(_ object: [String: Any], to name: String) throws {
        guard let session = session else { return }
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: session.appendingPathComponent(name), options: .atomic)
    }

    func command(_ action: String, address: String? = nil, enabled: Bool? = nil) {
        var object: [String: Any] = ["id": UUID().uuidString, "action": action]
        if let address = address { object["address"] = address }
        if let enabled = enabled { object["enabled"] = enabled }
        do { try write(object, to: "command.json") }
        catch { fail("Could not send command: \(error.localizedDescription)") }
    }

    func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func appleQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func start() {
        guard !preview, !active, backend == nil else { return }
        do {
            // macOS sockaddr_un.sun_path is only 104 bytes. Keep IPC paths short.
            let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("raw-bt-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            session = folder
            eventOffset = 0
            pending = Data()
            devices = [:]
            selection = nil
            errorMessage = nil
            connectedAddresses = []
            pendingAddress = nil
            pairingCode = nil
            reportCounts = [:]
            reports = 0
            stopping = false
            try Data().write(to: folder.appendingPathComponent("heartbeat"))
            if AXIsProcessTrusted() && savedDevices.values.contains(true) {
                pointer = try PointerServer(path: folder.appendingPathComponent("pointer.sock").path, sensitivity: mouseSensitivity, scrollSensitivity: scrollSensitivity)
            }
            FileManager.default.createFile(atPath: folder.appendingPathComponent("backend.log").path, contents: nil)
            let python = source.appendingPathComponent(".venv/bin/python").path
            let script = source.appendingPathComponent("gui_backend.py").path
            let shell = "\(shellQuote(python)) -u \(shellQuote(script)) --session \(shellQuote(folder.path)) > \(shellQuote(folder.appendingPathComponent("backend.log").path)) 2>&1"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \(appleQuote(shell)) with administrator privileges"]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.poll()
                    self.backend = nil
                    self.active = false
                    self.scanning = false
                    self.connectedAddresses = []
                    self.pendingAddress = nil
                    self.pairingCode = nil
                    self.stopPointer()
                    if process.terminationStatus != 0 && !self.stopping {
                        self.fail(message.contains("canceled") ? "Administrator request cancelled. You can scan again when ready." : "Adapter session ended. \(message.prefix(250))")
                    } else {
                        self.phase = "idle"
                        self.status = "Adapter released"
                    }
                    self.stopping = false
                }
            }
            backend = process
            active = true
            phase = "starting"
            status = "Authorize adapter access…"
            log("Requesting access to the USB Bluetooth adapter")
            try process.run()
        } catch {
            backend = nil
            active = false
            fail(error.localizedDescription)
        }
    }

    func scan() {
        if !active { start(); return }
        if busy { return }
        errorMessage = nil
        command("scan")
    }

    func pause() { command("pause") }

    func connect() {
        guard let device = chosen, active, !busy, !stopping else { return }
        guard device.connectable, !connectedAddresses.contains(device.address) else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            status = "Allow input control in Accessibility"
            log("Input control requires Raw Bluetooth Accessibility access")
            return
        }
        errorMessage = nil
        reports = 0
        do {
            if pointer == nil {
                guard let session = session else { return }
                pointer = try PointerServer(path: session.appendingPathComponent("pointer.sock").path, sensitivity: mouseSensitivity, scrollSensitivity: scrollSensitivity)
            }
            phase = "connecting"
            pendingAddress = device.address
            pairingCode = nil
            status = "Preparing \(device.title)…"
            command("connect", address: device.address)
        } catch { fail(error.localizedDescription) }
    }

    func disconnect() { command("disconnect", address: selection ?? pendingAddress) }
    func connectAudio() {
        guard let device = chosen, active, !stopping, device.category == "Audio" else { return }
        audioPendingAddress = device.address
        status = "Connecting to audio device…"
        command("audio_test", address: device.address)
    }
    func disconnectAudio() { command("audio_disconnect", address: selection) }
    func forget(_ device: NearbyDevice) { command("forget", address: device.address) }
    func stop() {
        guard active else { return }
        stopping = true
        status = "Releasing adapter…"
        phase = "stopping"
        command("stop")
    }
    func stopPointer() {
        pointer?.stop()
        pointer = nil
    }
    func fail(_ message: String) {
        errorMessage = message
        status = "Needs attention"
        if busy { phase = "paused"; pendingAddress = nil; pairingCode = nil }
        log(message)
    }

    func poll() {
        pointerAllowed = AXIsProcessTrusted()
        guard let session = session, active else { return }
        if pointerAllowed && pointer == nil && savedDevices.values.contains(true) && !stopping {
            do { pointer = try PointerServer(path: session.appendingPathComponent("pointer.sock").path, sensitivity: mouseSensitivity, scrollSensitivity: scrollSensitivity) }
            catch { log("Input server could not start: \(error.localizedDescription)") }
        }
        heartbeatCounter += 1
        if heartbeatCounter % 5 == 0 && !stopping {
            try? Data().write(to: session.appendingPathComponent("heartbeat"), options: .atomic)
        }
        guard let file = try? FileHandle(forReadingFrom: session.appendingPathComponent("events.jsonl")) else { return }
        defer { try? file.close() }
        do {
            let length = try file.seekToEnd()
            if length < eventOffset { eventOffset = 0; pending = Data() }
            try file.seek(toOffset: eventOffset)
            let data = try file.read(upToCount: 256 * 1024) ?? Data()
            eventOffset += UInt64(data.count)
            pending.append(data)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { receive(object) }
            }
        } catch { log("Could not read adapter updates") }
    }

    func receive(_ event: [String: Any]) {
        guard let state = event["state"] as? String else { return }
        if state == "saved", let address = event["address"] as? String {
            savedDevices[address] = event["auto_reconnect"] as? Bool ?? true
            return
        }
        if state == "forgotten", let address = event["address"] as? String {
            savedDevices.removeValue(forKey: address)
            audioAddresses.remove(address)
            connectedAddresses.remove(address)
            log("Forgot saved device (address)")
            return
        }
        if state == "device", let address = event["address"] as? String {
            let device = NearbyDevice(address: address, name: event["name"] as? String ?? "", rssi: event["rssi"] as? Int ?? -127, connectable: event["connectable"] as? Bool ?? false, classicAvailable: event["classic_available"] as? Bool ?? false, category: event["category"] as? String ?? "BLE device", lastSeen: Date(timeIntervalSince1970: event["last_seen"] as? Double ?? Date().timeIntervalSince1970))
            devices[address] = device
            if selection == nil && device.category == "Mouse" { selection = address }
            return
        }
        if state == "input" {
            reports = event["reports"] as? Int ?? reports
            if let address = event["address"] as? String { reportCounts[address] = event["reports"] as? Int ?? 0 }
            return
        }
        if state == "audio_connecting" {
            audioPendingAddress = event["address"] as? String
            status = "Opening A2DP audio connection…"
            return
        }
        if state == "audio_connected" {
            if let address = event["address"] as? String { audioAddresses.insert(address) }
            audioPendingAddress = nil
            status = "Audio connected · test tone playing"
            return
        }
        if state == "audio_disconnected" {
            if let address = event["address"] as? String { audioAddresses.remove(address) }
            audioPendingAddress = nil
            status = connectedAddresses.isEmpty ? "Audio disconnected" : "Input devices connected"
            return
        }
        if state == "audio_error" {
            audioPendingAddress = nil
            fail(event["message"] as? String ?? "Bluetooth audio connection failed")
            return
        }
        if state == "passkey" {
            pendingAddress = event["address"] as? String
            selection = pendingAddress
            pairingCode = event["code"] as? String
            status = "Type the pairing code on your keyboard"
            log("Keyboard pairing code displayed")
            return
        }
        if state == "error" { fail(event["message"] as? String ?? "Connection failed"); return }
        if state == "reconnect_wait" {
            if pendingAddress == event["address"] as? String { pendingAddress = nil; pairingCode = nil }
            log(event["message"] as? String ?? "Waiting for device to wake")
            status = connectedAddresses.isEmpty ? "Waiting for saved devices" : "\(connectedAddresses.count) input device(s) connected"
            return
        }
        if stopping && state != "stopped" { return }
        phase = state
        switch state {
        case "starting": status = "Taking control of adapter…"
        case "ready": status = "Adapter ready"
        case "scanning": scanning = true; status = connectedAddresses.isEmpty ? "Discovering nearby devices" : "\(connectedAddresses.count) input device(s) connected · scanning"
        case "paused": scanning = false; status = "Scan paused"
        case "connecting", "reconnecting": scanning = false; pendingAddress = event["address"] as? String; status = state == "reconnecting" ? "Reconnecting saved device…" : "Connecting…"
        case "pairing": status = "Establishing secure connection…"
        case "discovering": pairingCode = nil; status = "Reading input capabilities…"
        case "connected":
            if let address = event["address"] as? String { connectedAddresses.insert(address) }
            pendingAddress = nil
            pairingCode = nil
            status = "\(connectedAddresses.count) input device(s) connected"
            errorMessage = nil
        case "disconnected":
            if let address = event["address"] as? String {
                connectedAddresses.remove(address)
                if pendingAddress == address { pendingAddress = nil; pairingCode = nil }
            }
            status = connectedAddresses.isEmpty ? "Disconnected" : "\(connectedAddresses.count) input device(s) connected"
        case "stopped": active = false; scanning = false; connectedAddresses = []; pendingAddress = nil; pairingCode = nil; status = "Adapter released"; stopPointer()
        default: break
        }
        log(status)
    }
}

let ink = Color(red: 0.07, green: 0.09, blue: 0.13)
let panel = Color(red: 0.105, green: 0.125, blue: 0.17)
let accent = Color(red: 0.43, green: 0.91, blue: 0.75)
let muted = Color(red: 0.60, green: 0.65, blue: 0.73)

struct AppView: View {
    @ObservedObject var model: BluetoothModel
    @State var showSettings = false
    @State var diagnostics = false
    @State var keyboardTest = ""
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.07))
            HStack(spacing: 0) {
                sidebar.frame(width: 184)
                Divider().overlay(Color.white.opacity(0.07))
                deviceList.frame(minWidth: 310, idealWidth: 370)
                Divider().overlay(Color.white.opacity(0.07))
                details.frame(minWidth: 320, idealWidth: 390)
            }
            footer
        }
        .background(ink)
        .preferredColorScheme(.dark)
        .frame(minWidth: 980, minHeight: 650)
        .sheet(isPresented: $showSettings) { SettingsView(model: model) }
        .alert("Connection needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
            Button("Accessibility Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
        } message: { Text(model.errorMessage ?? "") }
    }
    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(accent)
                .frame(width: 48, height: 48).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                Text("Raw Bluetooth").font(.system(size: 22, weight: .semibold))
                Text("A direct connection to your devices.").font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).font(.system(size: 18)).foregroundStyle(muted)
                .accessibilityLabel("Settings")
            HStack(spacing: 7) {
                Circle().fill(model.connectedAddress != nil ? accent : model.scanning ? Color.blue : muted).frame(width: 7, height: 7)
                Text(model.status).font(.system(size: 12)).foregroundStyle(muted)
            }.padding(.horizontal, 13).padding(.vertical, 9).background(Color.white.opacity(0.04), in: Capsule())
            Button { model.scanning ? model.pause() : model.scan() } label: {
                Label(model.scanning ? "Pause scan" : "Scan devices", systemImage: model.scanning ? "pause.fill" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 10)
            }
            .buttonStyle(.plain).foregroundStyle(ink).background(accent, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel(model.scanning ? "Pause scan" : "Scan devices")
            .accessibilityIdentifier("scan")
            .disabled(model.busy || model.stopping || model.phase == "starting" || model.preview)
        }.padding(.horizontal, 25).padding(.vertical, 20)
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("LIBRARY").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(muted).padding(.bottom, 8)
            filterRow("All devices", icon: "square.grid.2x2", count: model.devices.count)
            filterRow("Mice", icon: "computermouse", count: model.devices.values.filter { $0.category == "Mouse" }.count)
            filterRow("Keyboards", icon: "keyboard", count: model.devices.values.filter { $0.category == "Keyboard" }.count)
            filterRow("Audio", icon: "airpodspro", count: model.devices.values.filter { $0.category == "Audio" }.count)
            filterRow("Saved", icon: "bookmark", count: model.savedDevices.count)
            filterRow("Connectable", icon: "link", count: model.devices.values.filter { $0.connectable }.count)
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("MOUSE SPEED").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(muted)
                    Spacer()
                    Text(String(format: "%.1f×", model.mouseSensitivity)).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                }
                Slider(value: $model.mouseSensitivity, in: 0.5...4.0, step: 0.1)
                    .tint(accent).accessibilityLabel("Mouse sensitivity")
                HStack {
                    Text("Slow").foregroundStyle(muted)
                    Spacer()
                    Text("Fast").foregroundStyle(muted)
                }.font(.system(size: 9))
            }.padding(11).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("SCROLL SPEED").font(.system(size: 9, weight: .semibold)).tracking(1.1).foregroundStyle(muted)
                    Spacer()
                    Text(String(format: "%.1f×", model.scrollSensitivity)).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent)
                }
                Slider(value: $model.scrollSensitivity, in: 0.5...4.0, step: 0.1)
                    .tint(accent).accessibilityLabel("Scroll sensitivity")
                HStack {
                    Text("Slow").foregroundStyle(muted)
                    Spacer()
                    Text("Fast").foregroundStyle(muted)
                }.font(.system(size: 9))
            }.padding(11).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            Spacer()
            if !model.pointerAllowed {
                Button {
                    _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } label: { Label("Enable input control", systemImage: "hand.raised") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(accent).padding(.bottom, 8).accessibilityLabel("Enable input control")
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack { Image(systemName: "usb.connector").foregroundStyle(accent); Text("USB adapter").fontWeight(.medium) }
                Text(model.active ? "In use by Raw Bluetooth" : "CSR · 0a12:0001").foregroundStyle(muted)
                Text("Other Bluetooth connections on this adapter pause while it’s in use.").foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                if model.active {
                    Button("Release adapter") { model.stop() }.buttonStyle(.plain).foregroundStyle(accent).disabled(model.stopping).accessibilityLabel("Release adapter")
                }
            }.font(.system(size: 11)).padding(13).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }.padding(17).background(Color.black.opacity(0.1))
    }
    func filterRow(_ title: String, icon: String, count: Int) -> some View {
        Button { model.filter = title } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 19)
                Text(title).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                Text("\(count)").font(.system(size: 10, design: .monospaced)).opacity(0.65)
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 11)
                .foregroundStyle(model.filter == title ? accent : muted)
                .background(model.filter == title ? accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
    var deviceList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Nearby devices").font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.scanning { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("Search name or address", text: $model.query).textFieldStyle(.plain).font(.system(size: 12))
            }.padding(11).background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            if model.visibleDevices.isEmpty {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: model.scanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(accent.opacity(0.65))
                    Text(model.scanning ? "Listening for devices" : model.devices.isEmpty ? "Find your next connection" : "No matching devices").font(.system(size: 14, weight: .medium))
                    Text(model.scanning ? "Put your mouse in pairing mode\nand keep it nearby." : "Start a scan to see nearby\nBluetooth Low Energy devices.").font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.visibleDevices) { device in deviceRow(device) }
                    }
                }
            }
            Text("\(model.visibleDevices.count) devices · BLE + Bluetooth Classic").font(.system(size: 10)).foregroundStyle(muted)
        }.padding(22)
    }
    func deviceRow(_ device: NearbyDevice) -> some View {
        Button { model.selection = device.address } label: {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.system(size: 20)).foregroundStyle(device.category == "Mouse" ? accent : muted)
                    .frame(width: 43, height: 45).background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(model.connectedAddresses.contains(device.address) ? "Connected" : device.lastSeen.timeIntervalSince1970 == 0 ? "Saved · waiting to wake" : device.name.isEmpty ? device.address : device.category).font(.system(size: 10)).foregroundStyle(model.connectedAddresses.contains(device.address) ? accent : muted)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(device.rssi > -65 ? accent : muted)
                    Text(device.rssi == -127 ? "—" : "\(device.rssi) dBm").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                }
            }.padding(11).background(model.selection == device.address ? accent.opacity(0.075) : Color.white.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selection == device.address ? accent.opacity(0.5) : Color.white.opacity(0.035), lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(device.title), \(device.category), \(device.rssi) dBm").accessibilityIdentifier(device.address)
    }
    var details: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 21) {
            Text("DEVICE DETAILS").font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(muted)
            if let device = model.chosen {
                VStack(spacing: 15) {
                    Image(systemName: device.symbol).font(.system(size: 48, weight: .light)).foregroundStyle(accent)
                        .frame(width: 104, height: 104).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 27))
                    Text(device.title).font(.system(size: 23, weight: .semibold)).multilineTextAlignment(.center)
                    Text(device.category.uppercased()).font(.system(size: 10, weight: .medium)).tracking(1.8).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                VStack(spacing: 15) {
                    info("Address", value: device.address)
                    info("Signal", value: device.rssi == -127 ? "Waiting for device" : "\(device.rssi) dBm · \(device.rssi > -65 ? "Strong" : device.rssi > -80 ? "Fair" : "Weak")")
                    info("Connection", value: device.connectable ? "Available" : "Broadcast only")
                }.padding(17).background(panel, in: RoundedRectangle(cornerRadius: 12))
                if let enabled = model.savedDevices[device.address] {
                    VStack(alignment: .leading, spacing: 7) {
                        Toggle("Reconnect automatically", isOn: Binding(get: { model.savedDevices[device.address] ?? enabled }, set: { value in
                            model.savedDevices[device.address] = value
                            model.command("remember", address: device.address, enabled: value)
                        })).toggleStyle(.switch).font(.system(size: 12))
                        Text("Reconnect when this device wakes. Disconnect pauses reconnection for this session.").font(.system(size: 10)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        Button("Forget saved device", role: .destructive) { model.forget(device) }
                            .font(.system(size: 11, weight: .medium)).padding(.top, 3)
                    }
                }
                if let code = model.pairingCode, model.pendingAddress == device.address {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TYPE ON YOUR KEYBOARD").font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(accent)
                        Text(code).font(.system(size: 34, weight: .bold, design: .monospaced)).tracking(4).textSelection(.enabled)
                        Text("Type these six digits on \(device.title), then press Enter. The digits won't appear in this window.").font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                        Button("Cancel pairing") { model.disconnect() }.buttonStyle(.plain).foregroundStyle(accent).accessibilityLabel("Cancel pairing")
                    }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                } else if model.audioAddresses.contains(device.address) {
                    HStack(spacing: 9) {
                        Image(systemName: "waveform").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A2DP audio is playing").font(.system(size: 12, weight: .semibold))
                            Text("Standalone Bluetooth playback · SBC").font(.system(size: 10)).foregroundStyle(muted)
                        }
                    }
                    Button { model.disconnectAudio() } label: { Text("Disconnect audio").frame(maxWidth: .infinity).padding(12) }
                        .buttonStyle(.plain).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                } else if model.connectedAddresses.contains(device.address) {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.category == "Keyboard" ? "Keyboard input is active" : "Mouse input is active").font(.system(size: 12, weight: .semibold))
                            Text("Encrypted connection · \((model.reportCounts[device.address] ?? 0).formatted()) reports").font(.system(size: 10)).foregroundStyle(muted)
                        }
                    }
                    Button { model.disconnect() } label: { Text("Disconnect").frame(maxWidth: .infinity).padding(12) }
                        .buttonStyle(.plain).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel("Disconnect")
                    if device.category == "Keyboard" {
                        TextField("Click here to test typing", text: $keyboardTest).textFieldStyle(.roundedBorder).accessibilityLabel("Keyboard test")
                    }
                } else {
                    Text(device.category == "Audio" && !device.classicAvailable ? "Waiting for a Classic Bluetooth inquiry result. Put AirPods in pairing mode and scan again." : !device.connectable ? "This device broadcasts information but is not accepting connections." : device.category == "Keyboard" ? "If a pairing code appears, type it on this keyboard and press Enter. Your mouse can stay connected." : device.category == "Audio" ? "Standalone A2DP playback is available for SBC audio devices. The test tone checks the direct Bluetooth audio path." : "Mouse and keyboard input are supported.")
                        .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Button { device.category == "Audio" ? model.connectAudio() : model.connect() } label: {
                        HStack {
                            if model.busy { ProgressView().controlSize(.small) }
                            Text(device.category == "Audio" ? (model.audioPendingAddress == device.address ? "Connecting…" : "Connect & play test tone") : model.busy ? "Connecting…" : device.category == "Keyboard" ? "Connect keyboard" : "Connect mouse").fontWeight(.semibold)
                        }.frame(maxWidth: .infinity).padding(12)
                    }.buttonStyle(.plain).foregroundStyle(ink).background(accent, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityLabel(model.busy ? "Connecting" : device.category == "Keyboard" ? "Connect keyboard" : "Connect mouse")
                        .disabled((device.category == "Audio" ? !device.classicAvailable || model.audioPendingAddress != nil : !device.connectable || model.busy) || !model.active || model.stopping)
                }
                Spacer(minLength: 0)
            } else {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: "cursorarrow.click").font(.system(size: 32, weight: .ultraLight)).foregroundStyle(muted)
                    Text("Select a device").font(.system(size: 16, weight: .medium))
                    Text("See its details and connect\nfrom here.").font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            }
        }.padding(25).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color.white.opacity(0.012))
    }
    func info(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(muted)
            Spacer()
            Text(value).font(.system(size: 11, design: label == "Address" ? .monospaced : .default)).textSelection(.enabled)
        }.font(.system(size: 11))
    }
    var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Color.white.opacity(0.07))
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(accent)
                Text("Direct USB discovery").foregroundStyle(muted)
                Spacer()
                Button { diagnostics.toggle() } label: { Label(diagnostics ? "Hide activity" : "Activity", systemImage: "terminal") }.buttonStyle(.plain).foregroundStyle(muted).accessibilityLabel(diagnostics ? "Hide activity" : "Activity")
            }.font(.system(size: 10)).padding(.horizontal, 22).padding(.vertical, 12)
            if diagnostics {
                ScrollView {
                    Text(model.logs.suffix(30).joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(15)
                }.frame(height: 115).background(Color.black.opacity(0.2))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: BluetoothModel
    var onDone: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { if let onDone = onDone { onDone() } else { dismiss() } }.keyboardShortcut(.defaultAction)
            }
            GroupBox("Startup") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled || model.loginNeedsApproval }, set: model.setLaunchAtLogin))
                        .disabled(model.preview)
                    if model.loginNeedsApproval {
                        Text("Allow Raw Bluetooth in System Settings → General → Login Items.").font(.caption)
                    }
                    if let error = model.loginError { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    Toggle("Start with the window hidden", isOn: $model.startHidden)
                    Toggle("Connect saved devices on launch", isOn: $model.connectOnLaunch)
                    Text("Adapter access may ask for an administrator password when a new session starts.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("Background") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Keep running when the window closes", isOn: $model.runInBackground)
                    Text("Your devices stay connected. Use the Bluetooth menu bar icon to reopen the window, release the adapter, or quit. Quit always stops the session.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("Administrator access") {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.active && model.phase != "starting" ? "Adapter session active" : "Authorization required for a new session", systemImage: "lock.shield")
                    Text("This build requests administrator access each time it starts the USB worker. Keeping it running in the background keeps that session available. Always-allowed access requires a separately installed, approved privileged helper; it is not available in this build. Your password is never stored.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }.padding(24).frame(width: 520).preferredColorScheme(.dark)
            .onAppear { model.refreshLoginStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshLoginStatus() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var window: NSWindow!
    let model = BluetoothModel()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Raw Bluetooth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApplication.shared.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.delegate = self
        window.isReleasedWhenClosed = false
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Raw Bluetooth")
        let statusMenu = NSMenu()
        for (title, action) in [("Open Raw Bluetooth", #selector(openWindow)), ("Settings…", #selector(openSettings)), ("Release adapter", #selector(releaseAdapter))] {
            let item = statusMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit Raw Bluetooth", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = statusMenu
        window.title = "Raw Bluetooth"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)
        window.contentView = NSHostingView(rootView: AppView(model: model))
        window.center()
        if !model.startHidden || model.preview || CommandLine.arguments.contains("--snapshot") {
            openWindow()
        }
        if !model.preview && (CommandLine.arguments.contains("--scan") || (model.connectOnLaunch && model.savedDevices.values.contains(true))) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.model.start() }
        }
        if model.preview && CommandLine.arguments.contains("--settings") { openSettings() }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let view = (self.settingsWindow ?? self.window)?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }
    @objc func openWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func openSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.appearance = NSAppearance(named: .darkAqua)
            settings.title = "Raw Bluetooth Settings"
            settings.isReleasedWhenClosed = false
            settings.contentView = NSHostingView(rootView: SettingsView(model: model, onDone: { [weak self] in self?.settingsWindow?.orderOut(nil) }))
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func releaseAdapter() { model.stop() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.runInBackground {
            sender.orderOut(nil)
        } else {
            NSApplication.shared.terminate(nil)
        }
        return false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !model.runInBackground }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.active else { return .terminateNow }
        model.stop()
        let start = Date()
        var closeTimer: Timer?
        closeTimer = Timer(timeInterval: 0.15, repeats: true) { _ in
            if !self.model.active || Date().timeIntervalSince(start) > 10 {
                closeTimer?.invalidate()
                self.model.stopPointer()
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        RunLoop.main.add(closeTimer!, forMode: .common)
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.command("stop")
        model.stopPointer()
    }
}

@main
struct RawBluetoothApplication {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
