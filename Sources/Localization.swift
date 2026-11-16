import Foundation

enum L10n {
    /// Returns the localized string for a given key, with optional formatting arguments.
    static func tr(_ key: String, _ args: CVarArg...) -> String {
        // Try Bundle.main first; fallback to Bundle for class if running in SPM/test harness
        let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        if args.isEmpty {
            return format
        }
        return String(format: format, locale: Locale.current, arguments: args)
    }
}

extension BatteryDevice {
    var localizedName: String {
        switch self {
        case .mac:        return L10n.tr("device.mac")
        case .phone:      return L10n.tr("device.phone")
        case .pad:        return L10n.tr("device.pad")
        case .watch:      return L10n.tr("device.watch")
        case .airPods:    return L10n.tr("device.airpods")
        case .keyboard:   return L10n.tr("device.keyboard")
        case .mouse:      return L10n.tr("device.mouse")
        case .trackpad:   return L10n.tr("device.trackpad")
        case .headphones: return L10n.tr("device.headphones")
        }
    }
}
