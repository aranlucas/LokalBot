import Foundation

/// macOS can draw its own grey inline prediction at the caret. With LokalBot's
/// autocomplete on as well, two suggestions compete in the same place.
/// Cotypist checks this setting and asks for the macOS one to be turned off;
/// the Autocomplete settings do the same.
enum CotypingSystemInlinePredictions {
    /// The global default behind Keyboard → Text Input → Edit… →
    /// "Show inline predictive text". macOS leaves it unset until the user
    /// changes it, and unset means on.
    static let defaultsKey = "NSAutomaticInlinePredictionEnabled"
    static let keyboardSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    static func isOn(globalDomain: [String: Any]?) -> Bool {
        switch globalDomain?[defaultsKey] {
        case let value as NSNumber: return value.boolValue
        case let value as String: return (value as NSString).boolValue
        default: return true
        }
    }

    static func isOn() -> Bool {
        isOn(globalDomain: UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain))
    }
}
