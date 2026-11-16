import Foundation

/// Shared by the menu bar app and the sandboxed WidgetKit extension.
struct WidgetBatteryDevice: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    let level: Int
    let isCharging: Bool
    let isPaused: Bool
    let chargingKnown: Bool
    let updatedAt: Date

    init(id: String, name: String, symbol: String, level: Int, isCharging: Bool,
          isPaused: Bool = false, updatedAt: Date, chargingKnown: Bool = true) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.level = level
        self.isCharging = chargingKnown && isCharging
        self.isPaused = isPaused
        self.chargingKnown = chargingKnown
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, symbol, level, isCharging, isPaused, updatedAt, chargingKnown
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(String.self, forKey: .id),
                  name: try values.decode(String.self, forKey: .name),
                  symbol: try values.decode(String.self, forKey: .symbol),
                  level: try values.decode(Int.self, forKey: .level),
                  isCharging: try values.decode(Bool.self, forKey: .isCharging),
                  isPaused: try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false,
                  updatedAt: try values.decode(Date.self, forKey: .updatedAt),
                  chargingKnown: try values.decodeIfPresent(Bool.self, forKey: .chargingKnown) ?? true)
    }

    var statusSymbol: String? {
        if !chargingKnown { return nil }
        if isPaused { return "pause.fill" }
        return isCharging ? "bolt.fill" : nil
    }

    var statusDescription: String {
        if !chargingKnown { return "Battery \(level)%" }
        if isPaused { return "Charging paused" }
        return isCharging ? "Charging" : "On battery"
    }

    func isStale(at date: Date) -> Bool {
        let age = date.timeIntervalSince(updatedAt)
        return !age.isFinite || age < -60 || age >= WidgetBatterySnapshot.staleInterval
    }
}

struct WidgetBatterySnapshot: Codable, Equatable {
    static let staleInterval: TimeInterval = 30 * 60
    let devices: [WidgetBatteryDevice]
    let writtenAt: Date

    static let empty = WidgetBatterySnapshot(devices: [], writtenAt: .distantPast)

    var displayedDevices: [WidgetBatteryDevice] { Array(devices.prefix(4)) }

    func displayedDevices(for layout: WidgetBatteryLayout) -> [WidgetBatteryDevice] {
        Array(devices.prefix(layout.capacity))
    }

    static func placeholder(at date: Date = Date(), layout: WidgetBatteryLayout = .fourWide) -> WidgetBatterySnapshot {
        let examples = [
            WidgetBatteryDevice(id: "mac", name: "MacBook", symbol: "macbook", level: 82, isCharging: true, updatedAt: date),
            WidgetBatteryDevice(id: "phone", name: "iPhone", symbol: "iphone", level: 64, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "airpods", name: "AirPods", symbol: "airpods", level: 47, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "watch", name: "Apple Watch", symbol: "applewatch", level: 91, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "pad", name: "iPad", symbol: "ipad", level: 20, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "keyboard", name: "Keyboard", symbol: "keyboard", level: 76, isCharging: false, updatedAt: date),
            WidgetBatteryDevice(id: "mouse", name: "Mouse", symbol: "computermouse", level: 15, isCharging: true, updatedAt: date),
            WidgetBatteryDevice(id: "case", name: "AirPods Case", symbol: "airpods.chargingcase", level: 92, isCharging: false, updatedAt: date)
        ]
        return WidgetBatterySnapshot(devices: Array(examples.prefix(layout.capacity)), writtenAt: date)
    }
}

enum WidgetBatteryLayout: String, CaseIterable {
    case single, fourSquare, fourWide, table

    var capacity: Int {
        switch self {
        case .single: return 1
        case .fourSquare, .fourWide: return 4
        case .table: return 8
        }
    }

    var columns: Int {
        switch self {
        case .single, .table: return 1
        case .fourSquare: return 2
        case .fourWide: return 4
        }
    }

    var isCompact: Bool { self == .fourSquare }

    var widgetKind: String {
        self == .fourWide ? "BartteryBatteries" : "BartteryBatteries.\(rawValue)"
    }
}

enum WidgetSnapshotStore {
    static let appGroup = "group.me.yura.barttery"
    static let widgetKind = "BartteryBatteries"
    static let widgetBundleId = "me.yura.barttery.widget"
    static let legacyWidgetBundleId = "com.yura.barttery.widget"

    static var defaultFileURL: URL {
        var homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            homePath = String(cString: pwDir)
        }
        let dir = URL(fileURLWithPath: homePath)
            .appendingPathComponent("Library/Group Containers/\(appGroup)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("battery-snapshot.json")
    }

    static var fileURL: URL? {
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return groupURL.appendingPathComponent("battery-snapshot.json")
        }
        return defaultFileURL
    }

    /// All locations where the snapshot can be stored or read.
    /// Includes the App Group container, the widget's dedicated sandbox container,
    /// and standard fallback directories.
    static func candidateURLs() -> [URL] {
        var urls: [URL] = []

        // 1. App Group container URL (if enabled by provisioning profile)
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            urls.append(groupURL.appendingPathComponent("battery-snapshot.json"))
        }

        // 2. Process's own document and application support directories
        // (inside the sandboxed widget extension, these map directly to its container:
        //  ~/Library/Containers/me.yura.barttery.widget/Data/Documents/)
        if let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(docURL.appendingPathComponent("battery-snapshot.json"))
        }
        if let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(appSupportURL.appendingPathComponent("battery-snapshot.json"))
        }

        // 3. User's real home directory paths (accessible to the host app)
        var homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            homePath = String(cString: pwDir)
        }

        for bundleId in [widgetBundleId, legacyWidgetBundleId] {
            let docsPath = "\(homePath)/Library/Containers/\(bundleId)/Data/Documents/battery-snapshot.json"
            let appSupportPath = "\(homePath)/Library/Containers/\(bundleId)/Data/Library/Application Support/battery-snapshot.json"
            urls.append(URL(fileURLWithPath: docsPath))
            urls.append(URL(fileURLWithPath: appSupportPath))
        }

        // 4. Default Group Containers folder path
        let groupPath = "\(homePath)/Library/Group Containers/\(appGroup)/battery-snapshot.json"
        urls.append(URL(fileURLWithPath: groupPath))

        // Deduplicate while preserving precedence
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let path = url.standardizedFileURL.path
            if !seen.contains(path) {
                seen.insert(path)
                result.append(url)
            }
        }
        return result
    }

    static func read(from url: URL? = fileURL) -> WidgetBatterySnapshot {
        guard let url else { return .empty }
        let targets = (url == fileURL) ? candidateURLs() : [url]

        var bestSnapshot: WidgetBatterySnapshot = .empty

        for targetURL in targets {
            var fileData: Data? = try? Data(contentsOf: targetURL)
            if fileData == nil {
                targetURL.withUnsafeFileSystemRepresentation { cPath in
                    guard let cPath else { return }
                    if let f = fopen(cPath, "rb") {
                        defer { fclose(f) }
                        fseek(f, 0, SEEK_END)
                        let len = ftell(f)
                        if len > 0 {
                            fseek(f, 0, SEEK_SET)
                            var buf = [UInt8](repeating: 0, count: len)
                            let readBytes = fread(&buf, 1, len, f)
                            if readBytes == len {
                                fileData = Data(buf)
                            }
                        }
                    }
                }
            }

            if let data = fileData,
               let snapshot = try? JSONDecoder().decode(WidgetBatterySnapshot.self, from: data) {
                if !snapshot.devices.isEmpty {
                    return snapshot
                }
                if bestSnapshot.devices.isEmpty {
                    bestSnapshot = snapshot
                }
            }
        }

        return bestSnapshot
    }

    static var lastFopenErrno: Int32 = 0

    static func write(_ snapshot: WidgetBatterySnapshot, to url: URL? = fileURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        let targets = (url == fileURL) ? candidateURLs() : [url]

        var successfulWrites = 0
        var firstError: Error?

        for targetURL in targets {
            do {
                try writeSingle(snapshot, to: targetURL)
                successfulWrites += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if successfulWrites == 0, let error = firstError {
            throw error
        }
    }

    private static func writeSingle(_ snapshot: WidgetBatterySnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var written = false
        lastFopenErrno = 0
        url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return }
            if let f = fopen(cPath, "wb") {
                defer { fclose(f) }
                data.withUnsafeBytes { ptr in
                    if let base = ptr.baseAddress {
                        fwrite(base, 1, data.count, f)
                    }
                }
                written = true
            } else {
                lastFopenErrno = errno
            }
        }
        if written { return }

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw error
        }
    }
}
