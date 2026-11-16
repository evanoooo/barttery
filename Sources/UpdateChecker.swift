import AppKit
import Foundation
import UserNotifications

class UpdateChecker {
    private static let lastCheckKey = "update.lastCheck"
    private static let releasesURL  = URL(string: "https://api.github.com/repos/yurastegny/barttery/releases/latest")!
    static let releasesPageURL      = "https://github.com/yurastegny/barttery/releases/latest"

    static func checkIfNeeded() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let elapsed = Date().timeIntervalSince1970 - last
        guard elapsed > 86400 else { return } // раз в сутки
        check()
    }

    static func check(manual: Bool = false) {
        var req = URLRequest(url: releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag  = json["tag_name"] as? String
            else {
                if manual {
                    openReleasesPage()
                }
                return
            }

            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

            let latest  = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if isNewer(latest, than: current) {
                DispatchQueue.main.async { notify(version: latest) }
            } else if manual {
                openReleasesPage()
            }
        }.resume()
    }

    private static func openReleasesPage() {
        guard let url = URL(string: releasesPageURL) else { return }
        DispatchQueue.main.async {
            NSWorkspace.shared.open(url)
        }
    }

    private static func notify(version: String) {
        let content = UNMutableNotificationContent()
        content.title = "Barttery \(version) available"
        content.body  = "Click to open the releases page"
        content.sound = .default
        content.userInfo = ["url": releasesPageURL]
        let req = UNNotificationRequest(identifier: "update-available", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private static func isNewer(_ a: String, than b: String) -> Bool {
        let av = a.split(separator: ".").compactMap { Int($0) }
        let bv = b.split(separator: ".").compactMap { Int($0) }
        let len = max(av.count, bv.count)
        for i in 0..<len {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
