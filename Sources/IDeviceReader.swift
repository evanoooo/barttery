import Foundation
import AppKit

struct WatchBattery: Equatable {
    let name: String
    let level: Int
    let isCharging: Bool
    var chargingKnown: Bool = true
    var updatedAt: Date = Date()
}

// Reads iPhone/iPad battery via bartbeat (legacy libimobiledevice transport)
// plus mobilebeat (Apple CoreDevice/RemotePairing transport), and Apple Watch
// battery via bartbeat/comptest when the paired iPhone transport supports it.
class IDeviceReader: NSObject {
    var onPhoneUpdate: ((Int?, Bool?, String?) -> Void)?
    var onPadUpdate:   ((Int?, Bool?, String?) -> Void)?
    var onWatchUpdate: ((WatchBattery?) -> Void)?

    private var binDir = ""
    private var bartbeat: Process?
    private var mobilebeat: Process?
    private var wifiwatch: Process?
    private var wifiwatchUDID: String?
    private var isQueryingWatch = false
    private var isStopped = false
    private var staleTimer: Timer?
    private var lastPhoneSuccess: Date?
    private var lastPadSuccess:   Date?
    private var lastWatchSuccess: Date?
    private var phoneUDID: String?
    private var lastBartbeatOutput: Date?
    private var lastBartbeatRestart: Date?
    // In-memory cache of the last successful sync times (avoids UserDefaults reads in checkStale).
    private var phoneSyncTime: Date?
    private var padSyncTime: Date?
    private var watchChargingState = WatchChargingState(
        observation: WatchChargingObservation.cached(), lastReading: WatchBattery.cached()
    )

    func start() {
        guard let resURL = Bundle.main.resourceURL else { return }
        binDir = resURL.path
        launchBartbeat()
        launchMobilebeat()
        launchWifiwatch()
        // Seed success timestamps from UserDefaults so the stale check works for
        // values restored from cache before any live bartbeat update arrives.
        let ud = UserDefaults.standard
        if let t = ud.object(forKey: "phone.lastSyncTime") as? Date {
            lastPhoneSuccess = t
            phoneSyncTime = t
        }
        if let t = ud.object(forKey: "pad.lastSyncTime") as? Date {
            lastPadSuccess = t
            padSyncTime = t
        }
        if let t = ud.object(forKey: "watch.lastSyncTime") as? Date { lastWatchSuccess = t }
        phoneUDID = ud.string(forKey: "phone.lastUDID")
        staleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkStale()
        }
        staleTimer?.tolerance = 3
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(onSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(onWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    deinit {
        isStopped = true
        staleTimer?.invalidate()
        staleTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for proc in [bartbeat, mobilebeat, wifiwatch] {
            if let proc, proc.isRunning {
                proc.terminate()
            }
        }
    }

    @objc private func onSleep() {
        staleTimer?.invalidate()
        staleTimer = nil
        for proc in [bartbeat, mobilebeat, wifiwatch] {
            if let proc, proc.isRunning {
                proc.terminate()
            }
        }
    }

    @objc private func onWake() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkStale()
        }
        staleTimer?.tolerance = 3
        lastBartbeatRestart = nil  // bypass cooldown on wake
        restartBartbeat()
    }

    /// Re-query Watch via comptest. Phone/pad come from bartbeat's own poll loop.
    func scanNow() {
        guard !isQueryingWatch else { return }
        let udid = phoneUDID ?? UserDefaults.standard.string(forKey: "phone.lastUDID")
        guard let udid else { return }
        phoneUDID = udid
        isQueryingWatch = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            defer { DispatchQueue.main.async { [weak self] in self?.isQueryingWatch = false } }
            self?.queryWatch(udid: udid)
        }
    }

    /// Kill and relaunch bartbeat, then re-query Watch. Used on popup open / wake.
    func forceReconnect() {
        lastBartbeatRestart = nil
        restartBartbeat()
        scanNow()
    }

    // MARK: - Helper pipe readers

    private func attachLineReader(to pipe: Pipe, onLine: @escaping (String) -> Void) {
        var lineBuf = Data()
        let newline: UInt8 = 0x0A
        let cr = CharacterSet(charactersIn: "\r")
        let maxLineBufferBytes = 65536

        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                if !lineBuf.isEmpty,
                   let trailing = String(data: lineBuf, encoding: .utf8)?
                       .trimmingCharacters(in: CharacterSet.newlines),
                   !trailing.isEmpty {
                    onLine(trailing)
                }
                lineBuf.removeAll(keepingCapacity: false)
                return
            }

            if lineBuf.count + data.count > maxLineBufferBytes {
                lineBuf.removeAll(keepingCapacity: false)
            }
            lineBuf.append(data)

            var searchStart = lineBuf.startIndex
            while let nlIndex = lineBuf[searchStart...].firstIndex(of: newline) {
                let slice = lineBuf[searchStart..<nlIndex]
                searchStart = lineBuf.index(after: nlIndex)
                if !slice.isEmpty,
                   let line = String(data: slice, encoding: .utf8)?.trimmingCharacters(in: cr),
                   !line.isEmpty {
                    onLine(line)
                }
            }
            if searchStart > lineBuf.startIndex {
                lineBuf.removeSubrange(lineBuf.startIndex..<searchStart)
            }
        }
    }

    private func attachStderrDrain(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { h in
            if h.availableData.isEmpty {
                h.readabilityHandler = nil
            }
        }
    }

    // MARK: - bartbeat process

    private func launchBartbeat() {
        guard !isStopped else { return }
        if let proc = bartbeat, proc.isRunning { return }
        let path = (binDir as NSString).appendingPathComponent("bartbeat")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)

        let outPipe = Pipe()
        let errPipe = Pipe()
        let inPipe  = Pipe()   // kept open so bartbeat's stdin doesn't get EOF
        proc.standardOutput = outPipe
        proc.standardInput  = inPipe
        proc.standardError  = errPipe

        attachLineReader(to: outPipe) { [weak self] line in
            self?.handle(line: line)
        }
        // Drain stderr so bartbeat's debug logging never fills the pipe buffer and
        // blocks its writer thread — an unread pipe is a classic way to wedge it.
        attachStderrDrain(to: errPipe)

        proc.terminationHandler = { [weak self, weak proc] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.isStopped else { return }
                if self.bartbeat == nil || self.bartbeat === proc {
                    self.launchBartbeat()
                }
            }
        }

        do {
            try proc.run()
            bartbeat = proc
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    /// Apple's MobileDevice.framework sees modern CoreDevice/RemotePairing
    /// devices that libimobiledevice cannot discover over Wi-Fi.
    private func launchMobilebeat() {
        guard !isStopped else { return }
        if let proc = mobilebeat, proc.isRunning { return }
        let path = (binDir as NSString).appendingPathComponent("mobilebeat")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = inPipe

        attachLineReader(to: outPipe) { [weak self] line in
            self?.handle(line: line)
        }
        attachStderrDrain(to: errPipe)

        proc.terminationHandler = { [weak self, weak proc] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.isStopped else { return }
                if self.mobilebeat == nil || self.mobilebeat === proc {
                    self.launchMobilebeat()
                }
            }
        }
        do {
            try proc.run()
            mobilebeat = proc
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    /// Reads the paired Watch over classic Wi-Fi lockdown, falling back to live
    /// power-source events when the iPhone refuses companion_proxy requests.
    private func launchWifiwatch() {
        guard !isStopped else { return }
        guard let udid = phoneUDID ?? UserDefaults.standard.string(forKey: "phone.lastUDID"),
              !udid.isEmpty else { return }

        if let proc = wifiwatch, proc.isRunning {
            if wifiwatchUDID == udid { return }
            proc.terminate()
            wifiwatch = nil
        }

        let path = (binDir as NSString).appendingPathComponent("wifiwatch")
        guard FileManager.default.fileExists(atPath: path) else { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [udid]

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        proc.standardInput  = inPipe

        attachLineReader(to: outPipe) { [weak self] line in
            self?.handleJSON(line)
        }
        attachStderrDrain(to: errPipe)

        proc.terminationHandler = { [weak self, weak proc] _ in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                guard let self, !self.isStopped else { return }
                if self.wifiwatch == nil || self.wifiwatch === proc {
                    self.launchWifiwatch()
                }
            }
        }

        do {
            try proc.run()
            wifiwatch = proc
            wifiwatchUDID = udid
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
        }
    }

    private func handle(line: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handle(line: line) }
            return
        }
        lastBartbeatOutput = Date()
        handleJSON(line)
    }

    private func handleJSON(_ line: String) {
        // All helpers can emit concurrently. Reconcile Watch state in one order
        // on the main queue, not concurrently from several pipe callbacks.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.handleJSON(line) }
            return
        }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {

        case "watch-stream":
            watchChargingState.streamHeartbeat(at: Date())

        case "phone":
            let level    = json["level"] as? Int
            let charging = json["charging"] as? Bool ?? false
            let name     = json["name"] as? String
            let udid     = json["udid"] as? String
            let now      = Date()
            lastPhoneSuccess = now
            if let udid { phoneUDID = udid; UserDefaults.standard.set(udid, forKey: "phone.lastUDID") }
            if let level {
                phoneSyncTime = now
                UserDefaults.standard.set(level, forKey: "phone.lastBattery")
                UserDefaults.standard.set(now, forKey: "phone.lastSyncTime")
                if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: "phone.lastName") }
            }
            onPhoneUpdate?(level, charging, name)
            launchWifiwatch()

        case "pad":
            let level    = json["level"] as? Int
            let charging = json["charging"] as? Bool ?? false
            let name     = json["name"] as? String
            let now      = Date()
            lastPadSuccess = now
            if let level {
                padSyncTime = now
                UserDefaults.standard.set(level, forKey: "pad.lastBattery")
                UserDefaults.standard.set(now, forKey: "pad.lastSyncTime")
                if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: "pad.lastName") }
            }
            onPadUpdate?(level, charging, name)

        case "connected":
            if json["device_type"] as? String == "phone", let udid = json["udid"] as? String {
                phoneUDID = udid
                UserDefaults.standard.set(udid, forKey: "phone.lastUDID")
                launchWifiwatch()
            }

        case "watch":
            guard let level = json["level"] as? Int, (0...100).contains(level) else { return }
            let reportedCharging = json["charging"] as? Bool
            let isPowerEvent = json["source"] as? String == "wifi-power-event"
            let now = Date()
            let reading = WatchBattery(
                name: json["name"] as? String ?? UserDefaults.standard.string(forKey: "watch.lastName") ?? "Apple Watch",
                level: level, isCharging: reportedCharging ?? false, updatedAt: now
            )
            if let watch = watchChargingState.receive(reading, powerEvent: isPowerEvent,
                                                      reportedCharging: reportedCharging, at: now) {
                if isPowerEvent, let observation = watchChargingState.observation {
                    UserDefaults.standard.set(observation.charging, forKey: "watch.lastPowerEventCharging")
                    UserDefaults.standard.set(observation.observedAt, forKey: "watch.lastPowerEventDate")
                }
                publishWatch(watch)
            }

        case "disconnected":
            break   // keep showing last known values

        default: break
        }
    }

    // MARK: - Apple Watch (via comptest)

    private func queryWatch(udid: String) {
        let out = run("comptest", [udid])
        if let watch = parseWatch(out) {
            applyWatch(watch)
            return
        }
        // Cable unplugged: read the Watch over Wi-Fi lockdown instead.
        let wifi = run("wifiwatch", [udid, "--once"], timeout: 60)
        applyWatchJSON(wifi)
    }

    private func applyWatch(_ watch: WatchBattery) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.applyWatch(watch) }
            return
        }
        if let watch = watchChargingState.receive(watch, powerEvent: false, reportedCharging: nil, at: Date()) {
            publishWatch(watch)
        }
    }

    private func publishWatch(_ watch: WatchBattery) {
        lastWatchSuccess = watch.updatedAt
        UserDefaults.standard.set(watch.level,      forKey: "watch.lastLevel")
        UserDefaults.standard.set(watch.isCharging, forKey: "watch.lastCharging")
        UserDefaults.standard.set(watch.name,       forKey: "watch.lastName")
        UserDefaults.standard.set(watch.updatedAt, forKey: "watch.lastSyncTime")
        onWatchUpdate?(watch)
    }

    private func applyWatchJSON(_ output: String) {
        for line in output.components(separatedBy: "\n") {
            guard line.hasPrefix("{"),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "watch",
                  let level = json["level"] as? Int,
                  (0...100).contains(level) else { continue }
            // Keep source/charging metadata from one-shot power events too;
            // converting to a registry WatchBattery would discard its authority.
            handleJSON(line)
        }
    }

    private func parseWatch(_ output: String) -> WatchBattery? {
        var name     = ""
        var level    = -1
        var charging = false
        var inWatch  = false
        for line in output.components(separatedBy: "\n") {
            if line.contains("Checking watch") { inWatch = true }
            guard inWatch else { continue }
            if line.contains("DeviceName")             { name     = line.value(for: "DeviceName") }
            if line.contains("BatteryCurrentCapacity") { level    = Int(line.value(for: "BatteryCurrentCapacity")) ?? -1 }
            if line.contains("BatteryIsCharging")      { charging = line.value(for: "BatteryIsCharging").lowercased() == "true" }
        }
        guard level >= 0 else { return nil }
        return WatchBattery(name: name.isEmpty ? "Apple Watch" : name, level: level, isCharging: charging)
    }

    // MARK: - Stale timeouts

    private func restartBartbeat() {
        let cooldown: TimeInterval = 180
        if let last = lastBartbeatRestart, Date().timeIntervalSince(last) < cooldown { return }
        lastBartbeatRestart = Date()
        lastBartbeatOutput  = Date()  // reset so we don't loop immediately
        // Prefer SIGKILL: a wedged bartbeat can ignore SIGTERM and stay alive for hours.
        if let proc = bartbeat, proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
        bartbeat = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.launchBartbeat()
        }
    }

    private func checkStale() {
        let now = Date()
        if let watch = watchChargingState.expire(at: now) {
            // Invalidate only the charging observation, preserving the actual
            // battery measurement date and never inventing "not charging".
            publishWatch(watch)
        }
        let deviceTimeout: TimeInterval = 1800

        // Restart bartbeat if stdout has been silent for 3 min — even when success
        // timestamps were already cleared. Otherwise a wedged daemon is never replaced.
        let silent = lastBartbeatOutput.map { now.timeIntervalSince($0) > 180 }
            ?? (bartbeat?.isRunning == true && now.timeIntervalSince(lastBartbeatRestart ?? .distantPast) > 180)
        if silent {
            restartBartbeat()
        }

        // Keep trying to recover when ALL known phones/pads have stopped syncing,
        // even if bartbeat is still emitting non-battery noise (connected/etc).
        // Uses in-memory cached timestamps to avoid hammering UserDefaults every 15s.
        // Never restart if at least one paired device is actively syncing (e.g. an iPad is away from home).
        let phoneSyncAge = phoneSyncTime.map { now.timeIntervalSince($0) }
        let padSyncAge = padSyncTime.map { now.timeIntervalSince($0) }
        let hasPhone = phoneSyncTime != nil
        let hasPad   = padSyncTime != nil
        let phoneSyncStale = phoneSyncAge.map { $0 > deviceTimeout } ?? false
        let padSyncStale   = padSyncAge.map   { $0 > deviceTimeout } ?? false
        let allPairedStale = (hasPhone || hasPad) && (!hasPhone || phoneSyncStale) && (!hasPad || padSyncStale)
        if !silent, allPairedStale {
            restartBartbeat()
        }

        let phoneStale = lastPhoneSuccess.map { now.timeIntervalSince($0) > deviceTimeout } ?? false
        let padStale   = lastPadSuccess.map   { now.timeIntervalSince($0) > deviceTimeout } ?? false

        // Watch: hide after 30 minutes without a successful query
        if let t = lastWatchSuccess, now.timeIntervalSince(t) > deviceTimeout {
            lastWatchSuccess = nil
            DispatchQueue.main.async { [weak self] in self?.onWatchUpdate?(nil) }
        }

        // iPhone / iPad: hide after 30 minutes
        if phoneStale {
            lastPhoneSuccess = nil
            phoneSyncTime = nil
            DispatchQueue.main.async { [weak self] in
                self?.onPhoneUpdate?(nil, nil, nil)
            }
        }
        if padStale {
            lastPadSuccess = nil
            padSyncTime = nil
            DispatchQueue.main.async { [weak self] in self?.onPadUpdate?(nil, nil, nil) }
        }
    }

    // MARK: - Process helpers

    @discardableResult
    private func run(_ binary: String, _ args: [String], timeout: TimeInterval = 10) -> String {
        let path = (binDir as NSString).appendingPathComponent(binary)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        // Drain stderr to nullDevice to prevent deadlock when child process outputs >64KB
        proc.standardError  = FileHandle.nullDevice

        let sema = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in
            sema.signal()
        }

        var outputData = Data()
        let lock = NSLock()
        let readQueue = DispatchQueue(label: "me.yura.barttery.pipeRead", qos: .utility)
        let readGroup = DispatchGroup()
        readGroup.enter()
        readQueue.async {
            let d = out.fileHandleForReading.readDataToEndOfFile()
            lock.lock()
            outputData = d
            lock.unlock()
            readGroup.leave()
        }

        do {
            try proc.run()
            let waitResult = sema.wait(timeout: .now() + timeout)
            if waitResult == .timedOut && proc.isRunning {
                Self.stopTimedOutHelper(proc)
            }
            try? out.fileHandleForWriting.close()
            _ = readGroup.wait(timeout: .now() + 1.0)
            lock.lock()
            let res = String(data: outputData, encoding: .utf8) ?? ""
            lock.unlock()
            return res
        } catch {
            try? out.fileHandleForWriting.close()
            return ""
        }
    }

    static func stopTimedOutHelper(_ process: Process, grace: TimeInterval = 0.5) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

// MARK: - String helpers

private extension String {
    func value(for key: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(key + ":") {
            return trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        }
        for line in components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + ":") {
                return t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }
}
