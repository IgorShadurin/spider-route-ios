import Foundation
import SwiftUI

struct AppLanguage: Identifiable, Hashable {
    let id: String
    let nativeName: String
    let isRTL: Bool

    var locale: Locale { Locale(identifier: id) }

    static let all: [AppLanguage] = [
        .init(id: "ar", nativeName: "العربية", isRTL: true),
        .init(id: "bn", nativeName: "বাংলা", isRTL: false),
        .init(id: "ca", nativeName: "Català", isRTL: false),
        .init(id: "cs", nativeName: "Čeština", isRTL: false),
        .init(id: "da", nativeName: "Dansk", isRTL: false),
        .init(id: "de", nativeName: "Deutsch", isRTL: false),
        .init(id: "el", nativeName: "Ελληνικά", isRTL: false),
        .init(id: "en-AU", nativeName: "English (Australia)", isRTL: false),
        .init(id: "en-CA", nativeName: "English (Canada)", isRTL: false),
        .init(id: "en-GB", nativeName: "English (United Kingdom)", isRTL: false),
        .init(id: "en-US", nativeName: "English (United States)", isRTL: false),
        .init(id: "es-ES", nativeName: "Español (España)", isRTL: false),
        .init(id: "es-MX", nativeName: "Español (México)", isRTL: false),
        .init(id: "fi", nativeName: "Suomi", isRTL: false),
        .init(id: "fr", nativeName: "Français", isRTL: false),
        .init(id: "fr-CA", nativeName: "Français (Canada)", isRTL: false),
        .init(id: "gu", nativeName: "ગુજરાતી", isRTL: false),
        .init(id: "he", nativeName: "עברית", isRTL: true),
        .init(id: "hi", nativeName: "हिन्दी", isRTL: false),
        .init(id: "hr", nativeName: "Hrvatski", isRTL: false),
        .init(id: "hu", nativeName: "Magyar", isRTL: false),
        .init(id: "id", nativeName: "Bahasa Indonesia", isRTL: false),
        .init(id: "it", nativeName: "Italiano", isRTL: false),
        .init(id: "ja", nativeName: "日本語", isRTL: false),
        .init(id: "kn", nativeName: "ಕನ್ನಡ", isRTL: false),
        .init(id: "ko", nativeName: "한국어", isRTL: false),
        .init(id: "ml", nativeName: "മലയാളം", isRTL: false),
        .init(id: "mr", nativeName: "मराठी", isRTL: false),
        .init(id: "ms", nativeName: "Bahasa Melayu", isRTL: false),
        .init(id: "nl", nativeName: "Nederlands", isRTL: false),
        .init(id: "no", nativeName: "Norsk", isRTL: false),
        .init(id: "or", nativeName: "ଓଡ଼ିଆ", isRTL: false),
        .init(id: "pa", nativeName: "ਪੰਜਾਬੀ", isRTL: false),
        .init(id: "pl", nativeName: "Polski", isRTL: false),
        .init(id: "pt-BR", nativeName: "Português (Brasil)", isRTL: false),
        .init(id: "pt-PT", nativeName: "Português (Portugal)", isRTL: false),
        .init(id: "ro", nativeName: "Română", isRTL: false),
        .init(id: "ru", nativeName: "Русский", isRTL: false),
        .init(id: "sk", nativeName: "Slovenčina", isRTL: false),
        .init(id: "sl", nativeName: "Slovenščina", isRTL: false),
        .init(id: "sv", nativeName: "Svenska", isRTL: false),
        .init(id: "ta", nativeName: "தமிழ்", isRTL: false),
        .init(id: "te", nativeName: "తెలుగు", isRTL: false),
        .init(id: "th", nativeName: "ไทย", isRTL: false),
        .init(id: "tr", nativeName: "Türkçe", isRTL: false),
        .init(id: "uk", nativeName: "Українська", isRTL: false),
        .init(id: "ur", nativeName: "اردو", isRTL: true),
        .init(id: "vi", nativeName: "Tiếng Việt", isRTL: false),
        .init(id: "zh-Hans", nativeName: "简体中文", isRTL: false),
        .init(id: "zh-Hant", nativeName: "繁體中文", isRTL: false)
    ]

    static func normalized(_ identifier: String) -> String {
        let clean = identifier.replacingOccurrences(of: "_", with: "-")
        let lower = clean.lowercased()
        if lower == "en" { return "en-US" }
        if lower == "es" { return "es-ES" }
        if lower == "iw" || lower.hasPrefix("iw-") { return "he" }
        if lower == "in" || lower.hasPrefix("in-") { return "id" }
        if lower == "nb" || lower == "nn" || lower.hasPrefix("nb-") || lower.hasPrefix("nn-") { return "no" }
        if lower.hasPrefix("zh") { return lower.contains("hant") || lower.contains("tw") || lower.contains("hk") ? "zh-Hant" : "zh-Hans" }
        if let exact = all.first(where: { $0.id.caseInsensitiveCompare(clean) == .orderedSame }) { return exact.id }
        let language = lower.split(separator: "-").first.map(String.init) ?? lower
        return all.first(where: { $0.id.lowercased() == language || $0.id.lowercased().hasPrefix(language + "-") })?.id ?? "en-US"
    }

    static var deviceDefault: AppLanguage {
        let identifiers = Locale.preferredLanguages.map(normalized)
        return identifiers.compactMap { id in all.first(where: { $0.id == id }) }.first
            ?? all.first(where: { $0.id == "en-US" })!
    }
}

@MainActor
final class LanguageManager: ObservableObject {
    @Published var selected: AppLanguage {
        didSet {
            UserDefaults.standard.set(selected.id, forKey: storageKey)
            locale = selected.locale
        }
    }
    @Published private(set) var locale: Locale
    private let storageKey = "app_language_preference"

    init() {
        let language: AppLanguage
        if let stored = UserDefaults.standard.string(forKey: storageKey) {
            let normalized = AppLanguage.normalized(stored)
            language = AppLanguage.all.first(where: { $0.id == normalized }) ?? .deviceDefault
        } else {
            language = .deviceDefault
        }
        selected = language
        locale = language.locale
    }
}

enum L10n {
    static var locale: Locale {
        let stored = UserDefaults.standard.string(forKey: "app_language_preference")
        return Locale(identifier: AppLanguage.normalized(stored ?? Locale.preferredLanguages.first ?? "en-US"))
    }

    static func tr(_ key: String) -> String {
        let stored = UserDefaults.standard.string(forKey: "app_language_preference")
        let identifier = AppLanguage.normalized(stored ?? Locale.preferredLanguages.first ?? "en-US")
        let fallbacks = [identifier, identifier.split(separator: "-").first.map(String.init), "en"].compactMap { $0 }
        for fallback in fallbacks {
            if let path = Bundle.main.path(forResource: fallback, ofType: "lproj"), let bundle = Bundle(path: path) {
                let value = bundle.localizedString(forKey: key, value: nil, table: "Localizable")
                if value != key { return value }
            }
        }
        return NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: locale, arguments: arguments)
    }
}
