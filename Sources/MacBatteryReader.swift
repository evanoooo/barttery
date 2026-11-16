import IOKit
import IOKit.ps
import Foundation

enum ChargeState {
    case discharging
    case charging
    case paused   // optimized charging hold
    case plugged  // on AC, fully charged
}

struct MacBattery: Equatable {
    let level: Int
    let state: ChargeState
    let cycleCount: Int
    let minutesToFull: Int?
    let minutesToEmpty: Int?
}

class MacBatteryReader {
    var onUpdate: ((MacBattery?) -> Void)?
    private var runLoopSource: CFRunLoopSource?

    func start() {
        stop()
        let context = Unmanaged.passUnretained(self).toOpaque()

        let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let reader = Unmanaged<MacBatteryReader>.fromOpaque(ctx).takeUnretainedValue()
            reader.publish()
        }, context)

        if let src = src?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = src
        }
        publish()
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            CFRunLoopSourceInvalidate(src)
            runLoopSource = nil
        }
    }

    func read() -> MacBattery? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var propsRef: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let props = propsRef?.takeRetainedValue() as? [String: Any]
        else { return nil }

        // CurrentCapacity is Apple's smoothed percentage — matches the menu bar and AlDente.
        // Raw mAh (RemainingCapacity / FullChargeCapacity) diverges because of charge smoothing.
        let battData = props["BatteryData"] as? [String: Any]
        let level: Int
        if let pct = battData?["CurrentCapacity"] as? Int ?? props["CurrentCapacity"] as? Int, pct > 0 {
            level = min(100, pct)
        } else {
            let remaining = battData?["RemainingCapacity"] as? Int
                         ?? props["AppleRawCurrentCapacity"] as? Int
            let fullCharge = battData?["FullChargeCapacity"] as? Int
                          ?? props["AppleRawMaxCapacity"] as? Int
            guard let r = remaining, let f = fullCharge, f > 0 else { return nil }
            level = min(100, Int(ceil(Double(r) / Double(f) * 100)))
        }
        let isCharging  = props["IsCharging"]         as? Bool ?? false
        let acConnected = props["ExternalConnected"]  as? Bool ?? false

        let state: ChargeState = isCharging ? .charging : acConnected ? (level >= 100 ? .plugged : .paused) : .discharging
        let cycleCount = props["CycleCount"] as? Int ?? 0

        func validMinutes(_ key: String) -> Int? {
            guard let v = props[key] as? Int, v >= 0, v < 65535 else { return nil }
            return Swift.max(v, 1)
        }

        var minutesToFull: Int? = nil
        var minutesToEmpty: Int? = nil

        if state == .charging {
            minutesToFull = validMinutes("AvgTimeToFull")
        } else if state == .discharging {
            minutesToEmpty = validMinutes("TimeRemaining")
        }

        return MacBattery(level: level, state: state, cycleCount: cycleCount,
                          minutesToFull: minutesToFull, minutesToEmpty: minutesToEmpty)
    }

    func readNow() { publish() }

    private func publish() {
        let battery = read()
        if Thread.isMainThread {
            onUpdate?(battery)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onUpdate?(battery)
            }
        }
    }

    deinit {
        stop()
    }
}
