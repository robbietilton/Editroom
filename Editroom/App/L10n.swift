import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func fmt(_ key: String, _ args: CVarArg...) -> String {
        String(format: tr(key), locale: .current, arguments: args)
    }
}
