import AppKit
import SwiftUI
import Foundation
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

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
    @Published var adapterTransport = ""
    @Published var adapterID = UserDefaults.standard.string(forKey: "adapterID") ?? "" {
        didSet { UserDefaults.standard.set(adapterID, forKey: "adapterID") }
    }
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
    @Published var pointerAllowed = false
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
    @Published var scrollPageLength: Double = min(30, max(1, UserDefaults.standard.object(forKey: "scrollPageLength") as? Double ?? 1)) {
        didSet {
            UserDefaults.standard.set(scrollPageLength, forKey: "scrollPageLength")
            pointer?.setScrollPageLength(scrollPageLength)
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
    @Published var inputDiagnosticsEnabled = UserDefaults.standard.bool(forKey: "inputDiagnosticsEnabled") {
        didSet {
            UserDefaults.standard.set(inputDiagnosticsEnabled, forKey: "inputDiagnosticsEnabled")
            if !inputDiagnosticsEnabled { inputDiagnostics = nil }
            pointer?.setDiagnosticsEnabled(inputDiagnosticsEnabled)
        }
    }
    @Published var inputDiagnostics: InputDiagnostics?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var loginError: String?
    @Published var usbServiceAvailable = FileManager.default.fileExists(atPath: "/var/run/raw-bluetooth-\(getuid())/usb.sock")
    @Published var installingUSBService = false

    func installUSBService() {
        guard !preview, !active, !installingUSBService else { return }
        let installer = packagedWorker == nil
            ? source.appendingPathComponent("packaging/usb-service-install.sh")
            : Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/usb-service-install.sh")
        let worker = packagedWorker == nil
            ? source.appendingPathComponent("build/release/image/Raw Bluetooth.app/Contents/Helpers/backend.app")
            : Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/backend.app")
        guard FileManager.default.fileExists(atPath: worker.path) else {
            fail("Build the packaged backend before installing USB access.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let shell = "/bin/zsh \(shellQuote(installer.path)) install \(getuid()) \(shellQuote(worker.path)) \(shellQuote(dataDirectory.path))"
        process.arguments = ["-e", "do shell script \(appleQuote(shell)) with administrator privileges"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let self = self else { return }
                self.installingUSBService = false
                self.usbServiceAvailable = FileManager.default.fileExists(atPath: "/var/run/raw-bluetooth-\(getuid())/usb.sock")
                if process.terminationStatus != 0 { self.fail("USB access installation failed. \(message.prefix(250))") }
                else { self.log("USB service installed; administrator access is no longer needed for sessions") }
            }
        }
        do {
            installingUSBService = true
            try process.run()
        } catch {
            installingUSBService = false
            fail(error.localizedDescription)
        }
    }

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
    var sessionChannel: SessionChannel?
    var heartbeatTimer: DispatchSourceTimer?
    var sessionActivity: NSObjectProtocol?
    var systemAudioCapture: SystemAudioCapture?

    func startHeartbeat() {
        stopHeartbeat()
        // Input forwarding is an active service even with the window hidden.
        // Allow normal system sleep while preventing App Nap timer throttling.
        sessionActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Forwarding Bluetooth mouse and keyboard input")
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.rawbluetooth.heartbeat"))
        timer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sessionChannel?.send(["type": "heartbeat"]) }
        heartbeatTimer = timer
        timer.resume()
    }

    func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        if let activity = sessionActivity { ProcessInfo.processInfo.endActivity(activity) }
        sessionActivity = nil
    }
    let source: URL
    let dataDirectory: URL
    let packagedWorker: URL?
    let preview: Bool

    init() {
        source = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "DriverSourceDirectory") as? String ?? FileManager.default.currentDirectoryPath)
        let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/backend.app/Contents/MacOS/raw-bluetooth-backend")
        packagedWorker = FileManager.default.isExecutableFile(atPath: worker.path) ? worker : nil
        dataDirectory = packagedWorker == nil ? source : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Raw Bluetooth")
        preview = CommandLine.arguments.contains("--preview")
        if let data = try? Data(contentsOf: dataDirectory.appendingPathComponent("saved-devices.json")),
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
            (filter != "Connected" || connectedAddresses.contains(device.address) || audioAddresses.contains(device.address)) &&
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

    func command(_ action: String, address: String? = nil, enabled: Bool? = nil, path: String? = nil) {
        var object: [String: Any] = ["id": UUID().uuidString, "action": action]
        if let address = address { object["address"] = address }
        if let enabled = enabled { object["enabled"] = enabled }
        if let path = path { object["path"] = path }
        guard let sessionChannel else { fail("Driver session is not ready"); return }
        sessionChannel.send(["type": "command", "command": object])
    }

    func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func appleQuote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    func start() {
        guard !preview, !active, backend == nil else { return }
        usbServiceAvailable = FileManager.default.fileExists(atPath: "/var/run/raw-bluetooth-\(getuid())/usb.sock")
        do {
            // macOS sockaddr_un.sun_path is only 104 bytes. Keep IPC paths short.
            let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent("raw-bt-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            session = folder
            let token = UUID().uuidString + UUID().uuidString
            sessionChannel = try SessionChannel(token: token) { [weak self] event in self?.receive(event) }
            devices = [:]
            selection = nil
            errorMessage = nil
            connectedAddresses = []
            pendingAddress = nil
            pairingCode = nil
            reportCounts = [:]
            reports = 0
            stopping = false
            if savedDevices.values.contains(true) {
                do { try startPointer() }
                catch { log("Accessibility input is unavailable: \(error.localizedDescription)") }
            }
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let python = source.appendingPathComponent(".venv/bin/python").path
            let script = source.appendingPathComponent("gui_backend.py").path
            let command = packagedWorker.map { "\(shellQuote($0.path)) --data-dir \(shellQuote(dataDirectory.path))" } ?? "\(shellQuote(python)) -u \(shellQuote(script))"
            let adapter = adapterID.trimmingCharacters(in: .whitespacesAndNewlines)
            let transport = adapter.isEmpty ? "auto" : "usb:" + adapter
            adapterTransport = ""
            guard let sessionChannel else { throw NSError(domain: "RawBluetooth", code: 3) }
            let shell = "\(command) --transport \(shellQuote(transport)) --session \(shellQuote(folder.path)) --session-port \(sessionChannel.port) --session-token \(shellQuote(token))"
            let process = Process()
            if usbServiceAvailable {
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", "exec " + shell]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", "do shell script \(appleQuote(shell)) with administrator privileges"]
            }
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] process in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.backend = nil
                    self.active = false
                    self.scanning = false
                    self.connectedAddresses = []
                    self.pendingAddress = nil
                    self.pairingCode = nil
                    self.stopPointer()
                    self.sessionChannel?.close()
                    self.sessionChannel = nil
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
            status = usbServiceAvailable ? "Opening adapter…" : "Authorize adapter access…"
            log(usbServiceAvailable ? "Connecting through the installed USB service" : "Requesting access to the USB Bluetooth adapter")
            try process.run()
            startHeartbeat()
        } catch {
            stopHeartbeat()
            sessionChannel?.close()
            sessionChannel = nil
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
        errorMessage = nil
        reports = 0
        do {
            try startPointer()
            phase = "connecting"
            pendingAddress = device.address
            pairingCode = nil
            status = "Preparing \(device.title)…"
            command("connect", address: device.address)
        } catch { fail(error.localizedDescription) }
    }

    func disconnect() { command("disconnect", address: selection ?? pendingAddress) }
    func connectAudio() {
        guard let device = chosen, !stopping, device.category == "Audio",
              audioPendingAddress == nil else { return }
        guard active else { start(); return }
        guard device.classicAvailable else {
            status = "Searching for Bluetooth audio…"
            scan()
            return
        }
        guard let session else { return }
        let fifo = session.appendingPathComponent("system-audio.fifo")
        let capture = SystemAudioCapture(fifo: fifo)
        systemAudioCapture = capture
        audioPendingAddress = device.address
        status = "Starting system audio route…"
        Task {
            do {
                try await capture.start()
                await MainActor.run {
                    self.status = "Connecting system audio…"
                    self.command("audio_system", address: device.address, path: fifo.path)
                }
            } catch {
                await MainActor.run {
                    capture.stop()
                    self.systemAudioCapture = nil
                    self.audioPendingAddress = nil
                    self.fail("System audio capture failed: \(error.localizedDescription)")
                }
            }
        }
    }
    func playAudioFile() {
        guard let device = chosen, active, !stopping, device.category == "Audio",
              device.classicAvailable, audioPendingAddress == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["wav", "mp3", "flac", "m4a"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        audioPendingAddress = device.address
        status = "Connecting to audio device…"
        command("audio_play", address: device.address, path: url.path)
    }
    func disconnectAudio() {
        systemAudioCapture?.stop()
        systemAudioCapture = nil
        command("audio_disconnect", address: selection)
    }
    func forget(_ device: NearbyDevice) { command("forget", address: device.address) }
    func stop() {
        guard active else { return }
        stopping = true
        status = "Releasing adapter…"
        phase = "stopping"
        command("stop")
    }
    func recoverAfterWake() {
        guard !preview, !stopping else { return }
        if active, let backend, backend.isRunning {
            // Restart discovery so the backend sees fresh advertisements and
            // can reconnect saved devices after their radios wake.
            scan()
        } else if active || backend != nil {
            // The USB worker may have timed out while macOS was asleep. Reset
            // its stale UI state so Start is available again.
            stopHeartbeat()
            sessionChannel?.close()
            sessionChannel = nil
            backend = nil
            active = false
            scanning = false
            connectedAddresses.removeAll()
            audioAddresses.removeAll()
            pendingAddress = nil
            audioPendingAddress = nil
            pairingCode = nil
            stopping = false
            status = "Restarting adapter after wake…"
            start()
        } else if connectOnLaunch && savedDevices.values.contains(true) {
            start()
        }
    }
    func stopPointer() {
        stopHeartbeat()
        pointer?.stop()
        pointer = nil
        pointerAllowed = false
        inputDiagnostics = nil
    }
    func fail(_ message: String) {
        errorMessage = message
        status = "Needs attention"
        if busy { phase = "paused"; pendingAddress = nil; pairingCode = nil }
        log(message)
    }

    func startPointer() throws {
        guard pointer == nil, let session else { return }
        guard AXIsProcessTrusted() else {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            throw NSError(domain: "RawBluetooth", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Raw Bluetooth in Accessibility to enable mouse and keyboard control, then connect again."])
        }
        pointer = try PointerServer(path: session.appendingPathComponent("pointer.sock").path,
                                    sensitivity: mouseSensitivity,
                                    scrollSensitivity: scrollSensitivity,
                                    scrollPageLength: scrollPageLength,
                                    diagnosticsEnabled: inputDiagnosticsEnabled) { [weak self] diagnostics in
            DispatchQueue.main.async { self?.inputDiagnostics = diagnostics }
        }
        pointerAllowed = true
    }

    func receive(_ event: [String: Any]) {
        guard let state = event["state"] as? String else { return }
        if state == "device_removed", let address = event["address"] as? String {
            devices.removeValue(forKey: address)
            if selection == address { selection = nil }
            return
        }
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
            // Scan timestamps change on every advertisement; only publish changes
            // that affect the displayed row (including saved-to-discovered state).
            if let previous = devices[address],
               previous.name == device.name, previous.rssi == device.rssi,
               previous.connectable == device.connectable,
               previous.classicAvailable == device.classicAvailable,
               previous.category == device.category,
               (previous.lastSeen.timeIntervalSince1970 == 0) == (device.lastSeen.timeIntervalSince1970 == 0) {
                return
            }
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
            status = event["message"] as? String ?? "Audio connected"
            return
        }
        if state == "audio_disconnected" {
            systemAudioCapture?.stop()
            systemAudioCapture = nil
            if let address = event["address"] as? String { audioAddresses.remove(address) }
            audioPendingAddress = nil
            if errorMessage == nil {
                status = connectedAddresses.isEmpty ? "Audio disconnected" : "Input devices connected"
            }
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
        if state == "adapter" {
            adapterTransport = event["transport"] as? String ?? ""
            log("Using USB adapter \(adapterTransport)")
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
        case "session_ending":
            log(event["message"] as? String ?? "Adapter session ending")
        case "stopped": active = false; scanning = false; connectedAddresses = []; pendingAddress = nil; pairingCode = nil; status = "Adapter released"; stopPointer()
        default: break
        }
        log(status)
    }
}

let ink = Color.black
let panel = Color.black
let accent = Color.green
let muted = Color.green.opacity(0.62)

struct AppView: View {
    @ObservedObject var model: BluetoothModel
    @State private var page: Page = .discover
    @State var keyboardTest = ""

    enum Page: String, CaseIterable, Identifiable {
        case discover = "Discover"
        case saved = "Saved"
        case connected = "Connected"
        case pointer = "Pointer"
        case adapter = "Adapter"
        case activity = "Activity"
        case settings = "Settings"

        var id: Self { self }

        var isDevicePage: Bool {
            [.discover, .saved, .connected].contains(self)
        }

        var icon: String {
            switch self {
            case .discover: return "dot.radiowaves.left.and.right"
            case .saved: return "bookmark"
            case .connected: return "link"
            case .pointer: return "cursorarrow.motionlines"
            case .adapter: return "usb.connector"
            case .activity: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }

        var titleKey: String {
            switch self {
            case .discover: return "Find and connect nearby devices"
            case .saved: return "Devices remembered for reconnection"
            case .connected: return "Devices in your current session"
            case .pointer: return "Tune mouse movement and scrolling"
            case .adapter: return "Manage your USB Bluetooth adapter"
            case .activity: return "Session events and diagnostics"
            case .settings: return "Startup and background preferences"
            }
        }
    }

    enum SidebarSection: CaseIterable, Identifiable {
        case devices
        case controls
        case system

        var id: Self { self }

        var title: String {
            switch self {
            case .devices: return "DEVICES"
            case .controls: return "CONTROLS"
            case .system: return "SYSTEM"
            }
        }

        var pages: [Page] {
            switch self {
            case .devices: return [.discover, .saved, .connected]
            case .controls: return [.pointer]
            case .system: return [.adapter, .activity, .settings]
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 224)
            Rectangle().fill(accent.opacity(0.14)).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(accent.opacity(0.14)).frame(height: 1)
                Group {
                    if page.isDevicePage {
                        HStack(spacing: 0) {
                            deviceList.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
                            Rectangle().fill(accent.opacity(0.14)).frame(width: 1)
                            details.frame(width: 320)
                        }
                    } else if page == .pointer { pointerPage }
                    else if page == .adapter { adapterPage }
                    else if page == .activity { activityPage }
                    else { SettingsView(model: model, embedded: true) }
                }
                footer
            }
        }
        .background(ink)
        .foregroundStyle(Color.green)
        .tint(accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 950, minHeight: 600)
        .alert("Connection needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(page.rawValue).font(.system(size: 23, weight: .semibold))
                Text(page.titleKey)
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill((!model.connectedAddresses.isEmpty || !model.audioAddresses.isEmpty || model.scanning) ? accent : muted).frame(width: 7, height: 7)
                Text(model.status).font(.system(size: 12)).foregroundStyle(muted).lineLimit(2)
            }.padding(.horizontal, 12).padding(.vertical, 8).overlay(Capsule().stroke(accent.opacity(0.18)))
            if page.isDevicePage {
                Button { model.scanning ? model.pause() : model.scan() } label: {
                    Label(model.scanning ? "Pause scan" : "Scan devices", systemImage: model.scanning ? "pause.fill" : "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 10)
                }
                .buttonStyle(.plain).foregroundStyle(ink).background(accent, in: RoundedRectangle(cornerRadius: 9))
                .accessibilityIdentifier("scan")
                .disabled(model.busy || model.stopping || model.phase == "starting" || model.preview)
            }
        }.padding(.horizontal, 25).padding(.vertical, 18)
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 19)).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RAW").font(.system(size: 13, weight: .bold)).tracking(2)
                    Text("BLUETOOTH").font(.system(size: 9, weight: .medium)).tracking(1.7).foregroundStyle(muted)
                }
            }.padding(.horizontal, 20).padding(.top, 27).padding(.bottom, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SidebarSection.allCases) { section in
                        sidebarHeading(section.title)
                        ForEach(section.pages) { pageItem in
                            navRow(pageItem, count: pageCount(for: pageItem))
                        }
                        if section != SidebarSection.allCases.last {
                            Rectangle().fill(accent.opacity(0.12)).frame(height: 1)
                                .padding(.horizontal, 24).padding(.vertical, 14)
                        }
                    }
                }.padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.active ? "ADAPTER IN USE" : "ADAPTER IDLE").font(.system(size: 10, weight: .semibold)).tracking(1.1)
                Text(model.active && !model.adapterTransport.isEmpty ? model.adapterTransport : "External USB Bluetooth")
                    .font(.system(size: 10)).foregroundStyle(muted).lineLimit(2)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(accent.opacity(0.16)))
                .padding(.horizontal, 14).padding(.bottom, 18)
        }.background(ink)
    }

    func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
            .padding(.horizontal, 24).padding(.bottom, 7)
    }

    func pageCount(for page: Page) -> Int? {
        switch page {
        case .discover: return model.devices.count
        case .saved: return model.savedDevices.count
        case .connected: return model.connectedAddresses.count + model.audioAddresses.count
        default: return nil
        }
    }

    func navRow(_ destination: Page, count: Int? = nil) -> some View {
        Button {
            page = destination
            if destination.isDevicePage {
                model.filter = destination == .discover ? "All devices" : destination.rawValue
                model.query = ""
                model.selection = nil
            }
            if destination == .settings { model.refreshLoginStatus() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: destination.icon).frame(width: 19)
                Text(destination.rawValue).lineLimit(1).minimumScaleFactor(0.8)
                Spacer()
                if let count = count { Text("\(count)").font(.system(size: 10, design: .monospaced)).opacity(0.65) }
            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 11).padding(.vertical, 11)
                .foregroundStyle(page == destination ? accent : muted)
                .background(page == destination ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .leading) {
                    if page == destination {
                        Capsule().fill(accent).frame(width: 3, height: 20)
                    }
                }
        }.buttonStyle(.plain).accessibilityLabel(destination.rawValue).padding(.horizontal, 12)
    }
    var deviceList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(page == .discover ? "Nearby devices" : page == .saved ? "Saved devices" : "Connected devices")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if model.scanning { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }
            if page == .discover {
                HStack(spacing: 6) {
                    ForEach(["All devices", "Mice", "Keyboards", "Audio", "Connectable"], id: \.self) { category in
                        Button(category == "All devices" ? "All" : category) { model.filter = category }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .foregroundStyle(model.filter == category ? Color.black : muted)
                            .background(model.filter == category ? accent : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(accent.opacity(0.2)))
                    }
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("Search name or address", text: $model.query).textFieldStyle(.plain).font(.system(size: 12))
            }.padding(11).background(Color.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            if model.visibleDevices.isEmpty {
                Spacer()
                VStack(spacing: 13) {
                    Image(systemName: model.scanning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(accent.opacity(0.65))
                    Text(page == .saved && model.query.isEmpty ? "No saved devices" : page == .connected && model.query.isEmpty ? "No connected devices" : !model.query.isEmpty || model.filter != "All devices" ? "No matching devices" : model.scanning ? "Listening for devices" : "Find your next connection").font(.system(size: 14, weight: .medium))
                    Text(page == .saved && model.query.isEmpty ? "Connect a device to save it for later." : page == .connected && model.query.isEmpty ? "Connected mice, keyboards, and audio devices appear here." : !model.query.isEmpty || model.filter != "All devices" ? "Try another search or category." : model.scanning ? "Put your device in pairing mode\nand keep it nearby." : "Start a scan to see nearby\nBLE and Bluetooth Classic devices.").font(.system(size: 12)).foregroundStyle(muted).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(model.visibleDevices) { device in deviceRow(device) }
                    }
                }
            }
            Text("\(model.visibleDevices.count) device\(model.visibleDevices.count == 1 ? "" : "s")").font(.system(size: 10)).foregroundStyle(muted)
        }.padding(22)
    }
    func deviceRow(_ device: NearbyDevice) -> some View {
        Button { model.selection = device.address } label: {
            HStack(spacing: 12) {
                Image(systemName: device.symbol).font(.system(size: 20)).foregroundStyle(device.category == "Mouse" ? accent : muted)
                    .frame(width: 43, height: 45).background(Color.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(device.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text((model.connectedAddresses.contains(device.address) || model.audioAddresses.contains(device.address)) ? "Connected" : device.lastSeen.timeIntervalSince1970 == 0 ? "Saved · waiting to wake" : device.name.isEmpty ? device.address : device.category).font(.system(size: 10)).foregroundStyle((model.connectedAddresses.contains(device.address) || model.audioAddresses.contains(device.address)) ? accent : muted)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(device.rssi > -65 ? accent : muted)
                    Text(device.rssi == -127 ? "—" : "\(device.rssi) dBm").font(.system(size: 9, design: .monospaced)).foregroundStyle(muted)
                    if !model.connectedAddresses.contains(device.address) && !model.audioAddresses.contains(device.address) {
                        Text(model.pendingAddress == device.address || model.audioPendingAddress == device.address ? "Connecting…" : "View details").font(.system(size: 9)).foregroundStyle(accent)
                    }
                }
            }.padding(11).background(model.selection == device.address ? accent.opacity(0.075) : Color.green.opacity(0.018), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selection == device.address ? accent.opacity(0.5) : Color.green.opacity(0.035), lineWidth: 1))
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
                    info("Connection", value: model.connectedAddresses.contains(device.address) || model.audioAddresses.contains(device.address) ? "Connected" : (device.category == "Audio" ? device.classicAvailable : device.connectable) ? "Available" : "Unavailable")
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
                            Text("System audio is routed").font(.system(size: 12, weight: .semibold))
                            Text("Mac output → Bluetooth · SBC").font(.system(size: 10)).foregroundStyle(muted)
                        }
                    }
                    Button { model.disconnectAudio() } label: { Text("Disconnect audio").frame(maxWidth: .infinity).padding(12) }
                        .buttonStyle(.plain).background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                } else if model.connectedAddresses.contains(device.address) {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.category == "Keyboard" ? "Keyboard input is active" : "Mouse input is active").font(.system(size: 12, weight: .semibold))
                            Text("Encrypted connection · \((model.reportCounts[device.address] ?? 0).formatted()) reports").font(.system(size: 10)).foregroundStyle(muted)
                        }
                    }
                    Button { model.disconnect() } label: { Text("Disconnect").frame(maxWidth: .infinity).padding(12) }
                        .buttonStyle(.plain).background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 9)).accessibilityLabel("Disconnect")
                    if device.category == "Keyboard" {
                        terminalTextField("Click here to test typing", text: $keyboardTest)
                            .accessibilityLabel("Keyboard test")
                    }
                } else {
                    Text(device.category == "Audio" && !device.classicAvailable ? "Run a Bluetooth Classic inquiry to confirm this device supports A2DP audio. Put AirPods in pairing mode if they are not found." : !device.connectable ? "This device broadcasts information but is not accepting connections." : device.category == "Keyboard" ? "If a pairing code appears, type it on this keyboard and press Enter. Your mouse can stay connected." : device.category == "Audio" ? "Route Mac system audio to this A2DP/SBC device. macOS will ask for system-audio recording permission." : "Mouse and keyboard input are supported.")
                        .font(.system(size: 11)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                    Button { device.category == "Audio" ? model.connectAudio() : model.connect() } label: {
                        HStack {
                            if model.pendingAddress == device.address || model.audioPendingAddress == device.address { ProgressView().controlSize(.small) }
                            Text(device.category == "Audio" ? (model.audioPendingAddress == device.address ? "Connecting…" : !model.active ? "Start adapter" : !device.classicAvailable ? "Find audio device" : "Route system audio") : model.pendingAddress == device.address ? "Connecting…" : device.category == "Keyboard" ? "Connect keyboard" : "Connect mouse").fontWeight(.semibold)
                        }.frame(maxWidth: .infinity).padding(12)
                    }.buttonStyle(.plain).foregroundStyle(ink).background(accent, in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityLabel(model.pendingAddress == device.address || model.audioPendingAddress == device.address ? "Connecting" : device.category == "Audio" ? "Route system audio" : device.category == "Keyboard" ? "Connect keyboard" : "Connect mouse")
                        .disabled((device.category == "Audio" ? model.audioPendingAddress != nil : !device.connectable || model.busy) || model.stopping)
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
        }.background(Color.green.opacity(0.012))
    }
    func info(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(muted)
            Spacer()
            Text(value).font(.system(size: 11, design: label == "Address" ? .monospaced : .default)).textSelection(.enabled)
        }.font(.system(size: 11))
    }
    var pointerPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("MOUSE").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
                controlCard("Mouse speed", description: "Adjust cursor movement for connected mice.", value: String(format: "%.1f×", model.mouseSensitivity)) {
                    Slider(value: $model.mouseSensitivity, in: 0.5...4.0, step: 0.1).accessibilityLabel("Mouse sensitivity")
                }
                Text("SCROLLING").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(muted).padding(.top, 8)
                controlCard("Scroll speed", description: "Adjust wheel sensitivity for connected mice.", value: String(format: "%.1f×", model.scrollSensitivity)) {
                    Slider(value: $model.scrollSensitivity, in: 0.5...4.0, step: 0.1).accessibilityLabel("Scroll sensitivity")
                }
                controlCard("Scroll page length", description: "Vertical lines per wheel step. Apps determine each line's height.", value: "\(Int(model.scrollPageLength)) lines") {
                    Slider(value: $model.scrollPageLength, in: 1...30, step: 1).accessibilityLabel("Scroll page length in lines per wheel step")
                }
                if !model.pointerAllowed {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Accessibility input is waiting to start").font(.system(size: 14, weight: .semibold))
                        Text("Allow Raw Bluetooth in System Settings → Privacy & Security → Accessibility, then connect a mouse or keyboard.").font(.system(size: 12)).foregroundStyle(muted)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2)))
                }
            }.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity).padding(30)
        }.background(ink)
    }
    func controlCard<Content: View>(_ title: String, description: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(value).font(.system(size: 12, design: .monospaced)).foregroundStyle(muted)
            }
            Text(description).font(.system(size: 12)).foregroundStyle(muted)
            content()
        }.padding(20).background(ink, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2)))
    }

    func terminalTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .padding(11)
            .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.2)))
    }
    var adapterPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("USB Bluetooth adapter", systemImage: "usb.connector").font(.system(size: 16, weight: .semibold))
                    Text(model.active && !model.adapterTransport.isEmpty ? model.adapterTransport : model.adapterID.isEmpty ? "External USB Bluetooth · automatic detection" : "USB · \(model.adapterID)")
                        .font(.system(size: 13)).foregroundStyle(muted)
                    Text("Other Bluetooth connections on this adapter pause while it is in use.").font(.system(size: 12)).foregroundStyle(muted)
                    if model.active {
                        Button("Release adapter") { model.stop() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35)))
                            .disabled(model.stopping)
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2)))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose adapter").font(.system(size: 15, weight: .semibold))
                    TextField("Automatic (or USB ID, e.g. 0a12:0001)", text: $model.adapterID)
                        .textFieldStyle(.plain).padding(11)
                        .background(accent.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.2)))
                        .disabled(model.active)
                    Text("Leave blank to detect an external adapter automatically. Release the adapter before changing this setting.")
                        .font(.system(size: 12)).foregroundStyle(muted)
                }.padding(20).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2)))
                VStack(alignment: .leading, spacing: 12) {
                    Label(model.usbServiceAvailable ? "USB access installed" : "USB access setup", systemImage: "lock.shield")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Install once with administrator approval. Reinstall after updating the app to update the service.")
                        .font(.system(size: 12)).foregroundStyle(muted)
                    Button(model.installingUSBService ? "Installing…" : model.usbServiceAvailable ? "Update USB access…" : "Install USB access…") { model.installUSBService() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.35)))
                        .disabled(model.active || model.preview || model.installingUSBService)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2)))
            }.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity).padding(30)
        }.background(ink)
    }
    var activityPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Recent activity").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text("Latest 150 events").font(.system(size: 11)).foregroundStyle(muted)
            }
            if model.inputDiagnosticsEnabled {
                let diagnostics = model.inputDiagnostics
                HStack(spacing: 10) {
                    Label("Input diagnostics", systemImage: "speedometer")
                    Spacer()
                    Text(diagnostics.map { "\($0.latestMotionAgeMilliseconds) ms latest · \($0.staleMotionDrops) stale motion dropped · \($0.largestReadBatch) packet batch" } ?? "Waiting for input…")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(muted)
                }.padding(.horizontal, 14).padding(.vertical, 11)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.green.opacity(0.2)))
            }
            ScrollView {
                Text(model.logs.isEmpty ? "No activity yet. Start a scan to see session events here." : model.logs.reversed().joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(model.logs.isEmpty ? muted : accent)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.2)))
        }.padding(30).background(ink)
    }
    var footer: some View {
        HStack {
            Image(systemName: "lock.shield")
            Text("Direct USB discovery")
            Spacer()
            Text("BLE + Bluetooth Classic")
        }.font(.system(size: 10)).foregroundStyle(muted)
            .padding(.horizontal, 25).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Color.green.opacity(0.14)).frame(height: 1) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: BluetoothModel
    var onDone: (() -> Void)? = nil
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            if !embedded {
                HStack {
                    Text("Settings").font(.title2.bold())
                    Spacer()
                    Button("Done") { if let onDone = onDone { onDone() } else { dismiss() } }.keyboardShortcut(.defaultAction)
                }
            }
            settingsCard("STARTUP") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled || model.loginNeedsApproval }, set: model.setLaunchAtLogin))
                        .disabled(model.preview)
                    if model.loginNeedsApproval {
                        Text("Allow Raw Bluetooth in System Settings → General → Login Items.").font(.caption).foregroundStyle(muted)
                    }
                    if let error = model.loginError { Text(error).font(.caption).foregroundStyle(accent) }
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                    Toggle("Start with the window hidden", isOn: $model.startHidden)
                    Toggle("Connect saved devices on launch", isOn: $model.connectOnLaunch)
                    Text("Install USB access from the Adapter page to connect automatically without repeated administrator prompts.")
                        .font(.caption).foregroundStyle(muted)
                }
            }
            settingsCard("BACKGROUND") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Keep running when the window closes", isOn: $model.runInBackground)
                    Text("Your devices stay connected. Use the Bluetooth menu bar icon to reopen the window, release the adapter, or quit. Quit always stops the session.")
                        .font(.caption).foregroundStyle(muted)
                }
            }
            settingsCard("DIAGNOSTICS") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show input latency diagnostics", isOn: $model.inputDiagnosticsEnabled)
                    Text("Shows recent transport age, dropped stale motion, and socket read batches. Pointer coordinates are never recorded.")
                        .font(.caption).foregroundStyle(muted)
                }
            }
        }.frame(maxWidth: 650, alignment: .leading).frame(maxWidth: .infinity).padding(30)
        }.frame(width: embedded ? nil : 520, height: embedded ? nil : 620).background(ink)
            .foregroundStyle(Color.green).tint(Color.green).preferredColorScheme(.dark)
            .onAppear { model.refreshLoginStatus() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshLoginStatus() }
    }

    func settingsCard<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(muted)
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ink, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(accent.opacity(0.2)))
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        window.title = "Raw Bluetooth"
        window.titlebarAppearsTransparent = false
        window.backgroundColor = .black
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
    @objc func systemDidWake(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.model.recoverAfterWake() }
    }
    @objc func openSettings() {
        if settingsWindow == nil {
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 568, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            settings.appearance = NSAppearance(named: .darkAqua)
            settings.backgroundColor = .black
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
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
