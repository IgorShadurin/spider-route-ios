import Foundation

enum WelcomePresentationStore {
    private static let key = "spiderroute_welcome_v2_dismissed"
    static var shouldPresentOnLaunch: Bool { !UserDefaults.standard.bool(forKey: key) }
    static func markDismissed() { UserDefaults.standard.set(true, forKey: key) }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
